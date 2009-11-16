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
local muc_name = module:get_option("name");
if type(muc_name) ~= "string" then muc_name = "Prosody Chatrooms"; end
local restrict_room_creation = module:get_option("restrict_room_creation");
if restrict_room_creation and restrict_room_creation ~= true then restrict_room_creation = nil; end
local history_length = 20;

local muc_new_room = module:require "muc".new_room;
local register_component = require "core.componentmanager".register_component;
local deregister_component = require "core.componentmanager".deregister_component;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza";
local uuid_gen = require "util.uuid".generate;
local datamanager = require "util.datamanager";
local um_is_admin = require "core.usermanager".is_admin;

local rooms = {};
local persistent_rooms = datamanager.load(nil, muc_host, "persistent") or {};
local component;

local function is_admin(jid)
	return um_is_admin(jid) or um_is_admin(jid, module.host);
end

local function room_route_stanza(room, stanza) core_post_stanza(component, stanza); end
local function room_save(room, forced)
	local node = jid_split(room.jid);
	persistent_rooms[room.jid] = room._data.persistent;
	if room._data.persistent then
		local history = room._data.history;
		room._data.history = nil;
		local data = {
			jid = room.jid;
			_data = room._data;
			_affiliations = room._affiliations;
		};
		datamanager.store(node, muc_host, "config", data);
		room._data.history = history;
	elseif forced then
		datamanager.store(node, muc_host, "config", nil);
	end
	if forced then datamanager.store(nil, muc_host, "persistent", persistent_rooms); end
end

for jid in pairs(persistent_rooms) do
	local node = jid_split(jid);
	local data = datamanager.load(node, muc_host, "config") or {};
	local room = muc_new_room(jid);
	room._data = data._data;
	room._affiliations = data._affiliations;
	room.route_stanza = room_route_stanza;
	room.save = room_save;
	rooms[jid] = room;
end

local host_room = muc_new_room(muc_host);
host_room.route_stanza = room_route_stanza;
host_room.save = room_save;

local function get_disco_info(stanza)
	return st.iq({type='result', id=stanza.attr.id, from=muc_host, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category='conference', type='text', name=muc_name}):up()
		:tag("feature", {var="http://jabber.org/protocol/muc"}); -- TODO cache disco reply
end
local function get_disco_items(stanza)
	local reply = st.iq({type='result', id=stanza.attr.id, from=muc_host, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#items");
	for jid, room in pairs(rooms) do
		if not room._data.hidden then
			reply:tag("item", {jid=jid, name=jid}):up();
		end
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
		elseif xmlns == "http://jabber.org/protocol/muc#unique" then
			origin.send(st.reply(stanza):tag("unique", {xmlns = xmlns}):text(uuid_gen())); -- FIXME Random UUIDs can theoretically have collisions
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
				if not(restrict_room_creation) or is_admin(stanza.attr.from) then
					room = muc_new_room(bare);
					room.route_stanza = room_route_stanza;
					room.save = room_save;
					rooms[bare] = room;
				end
			end
			if room then
				room:handle_stanza(origin, stanza);
				if not next(room._occupants) and not persistent_rooms[room.jid] then -- empty, non-persistent room
					rooms[bare] = nil; -- discard room
				end
			else
				origin.send(st.error_reply(stanza, "cancel", "not-allowed"));
			end
		else --[[not for us?]] end
		return;
	end
	-- to the main muc domain
	handle_to_domain(origin, stanza);
end);
function component.send(stanza) -- FIXME do a generic fix
	if stanza.attr.type == "result" or stanza.attr.type == "error" then
		core_post_stanza(component, stanza);
	else error("component.send only supports result and error stanzas at the moment"); end
end

prosody.hosts[module:get_host()].muc = { rooms = rooms };

module.unload = function()
	deregister_component(muc_host);
end
module.save = function()
	return {rooms = rooms};
end
module.restore = function(data)
	rooms = {};
	for jid, oldroom in pairs(data.rooms or {}) do
		local room = muc_new_room(jid);
		room._jid_nick = oldroom._jid_nick;
		room._occupants = oldroom._occupants;
		room._data = oldroom._data;
		room._affiliations = oldroom._affiliations;
		room.route_stanza = room_route_stanza;
		room.save = room_save;
		rooms[jid] = room;
	end
	prosody.hosts[module:get_host()].muc = { rooms = rooms };
end
