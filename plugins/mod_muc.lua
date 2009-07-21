-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


if module:get_host_type() ~= "component" then
	error("MUC should be loaded as a component, please see http://prosody.im/doc/components", 0);
end

local muc_host = module:get_host();
local muc_name = "Chatrooms";
local history_length = 20;

local muc_new_room = require "util.muc".new_room;
local register_component = require "core.componentmanager".register_component;
local deregister_component = require "core.componentmanager".deregister_component;
local jid_split = require "util.jid".split;
local st = require "util.stanza";

local rooms = {};
local component;
local host_room = muc_new_room(muc_host);
host_room.route_stanza = function(room, stanza) core_post_stanza(component, stanza); end;

local function get_disco_info(stanza)
	return st.iq({type='result', id=stanza.attr.id, from=muc_host, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category='conference', type='text', name=muc_name}):up()
		:tag("feature", {var="http://jabber.org/protocol/muc"}); -- TODO cache disco reply
end
local function get_disco_items(stanza)
	local reply = st.iq({type='result', id=stanza.attr.id, from=muc_host, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#items");
	for jid, room in pairs(rooms) do
		reply:tag("item", {jid=jid, name=jid}):up();
	end
	return reply; -- TODO cache disco reply
end

local function handle_to_domain(origin, stanza)
	local type = stanza.attr.type;
	if type == "error" or type == "result" then return; end
	if stanza.name == "iq" and type == "get" then
		local xmlns = stanza.tags[1].attr.xmlns;
		if xmlns == "http://jabber.org/protocol/disco#info" then
			origin.send(get_disco_info(stanza));
		elseif xmlns == "http://jabber.org/protocol/disco#items" then
			origin.send(get_disco_items(stanza));
		else
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- TODO disco/etc
		end
	else
		host_room:handle_stanza(origin, stanza);
		--origin.send(st.error_reply(stanza, "cancel", "service-unavailable", "The muc server doesn't deal with messages and presence directed at it"));
	end
end

component = register_component(muc_host, function(origin, stanza)
	local to_node, to_host, to_resource = jid_split(stanza.attr.to);
	if to_node then
		local bare = to_node.."@"..to_host;
		if to_host == muc_host or bare == muc_host then
			local room = rooms[bare];
			if not room then
				room = muc_new_room(bare);
				room.route_stanza = function(room, stanza) core_post_stanza(component, stanza); end;
				rooms[bare] = room;
			end
			room:handle_stanza(origin, stanza);
		else --[[not for us?]] end
		return;
	end
	-- to the main muc domain
	handle_to_domain(origin, stanza);
end);

prosody.hosts[module:get_host()].muc = { rooms = rooms };

module.unload = function()
	deregister_component(muc_host);
end
module.save = function()
	return {rooms = rooms};
end
module.restore = function(data)
	rooms = data.rooms or {};
	prosody.hosts[module:get_host()].muc = { rooms = rooms };
end
