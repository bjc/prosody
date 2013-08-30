-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local array = require "util.array";

if module:get_host_type() ~= "component" then
	error("MUC should be loaded as a component, please see http://prosody.im/doc/components", 0);
end

local muc_host = module:get_host();
local muc_name = module:get_option("name");
if type(muc_name) ~= "string" then muc_name = "Prosody Chatrooms"; end
local restrict_room_creation = module:get_option("restrict_room_creation");
if restrict_room_creation then
	if restrict_room_creation == true then
		restrict_room_creation = "admin";
	elseif restrict_room_creation ~= "admin" and restrict_room_creation ~= "local" then
		restrict_room_creation = nil;
	end
end
local muclib = module:require "muc";
local muc_new_room = muclib.new_room;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza";
local uuid_gen = require "util.uuid".generate;
local um_is_admin = require "core.usermanager".is_admin;
local hosts = prosody.hosts;

rooms = {};
local rooms = rooms;
local persistent_rooms_storage = module:open_store("persistent");
local persistent_rooms = persistent_rooms_storage:get() or {};
local room_configs = module:open_store("config");

-- Configurable options
muclib.set_max_history_length(module:get_option_number("max_history_messages"));

module:depends("disco");
module:add_identity("conference", "text", muc_name);
module:add_feature("http://jabber.org/protocol/muc");

local function is_admin(jid)
	return um_is_admin(jid, module.host);
end

local _set_affiliation = muc_new_room.room_mt.set_affiliation;
local _get_affiliation = muc_new_room.room_mt.get_affiliation;
function muclib.room_mt:get_affiliation(jid)
	if is_admin(jid) then return "owner"; end
	return _get_affiliation(self, jid);
end
function muclib.room_mt:set_affiliation(actor, jid, affiliation, callback, reason)
	if is_admin(jid) then return nil, "modify", "not-acceptable"; end
	return _set_affiliation(self, actor, jid, affiliation, callback, reason);
end

local function room_route_stanza(room, stanza) module:send(stanza); end
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
		room_configs:set(node, data);
		room._data.history = history;
	elseif forced then
		room_configs:set(node, nil);
		if not next(room._occupants) then -- Room empty
			rooms[room.jid] = nil;
		end
	end
	if forced then persistent_rooms_storage:set(nil, persistent_rooms); end
end

function create_room(jid)
	local room = muc_new_room(jid);
	room.route_stanza = room_route_stanza;
	room.save = room_save;
	rooms[jid] = room;
	module:fire_event("muc-room-created", { room = room });
	return room;
end

local persistent_errors = false;
for jid in pairs(persistent_rooms) do
	local node = jid_split(jid);
	local data = room_configs:get(node);
	if data then
		local room = create_room(jid);
		room._data = data._data;
		room._affiliations = data._affiliations;
	else -- missing room data
		persistent_rooms[jid] = nil;
		module:log("error", "Missing data for room '%s', removing from persistent room list", jid);
		persistent_errors = true;
	end
end
if persistent_errors then persistent_rooms_storage:set(nil, persistent_rooms); end

local host_room = muc_new_room(muc_host);
host_room.route_stanza = room_route_stanza;
host_room.save = room_save;

module:hook("host-disco-items", function(event)
	local reply = event.reply;
	module:log("debug", "host-disco-items called");
	for jid, room in pairs(rooms) do
		if not room:get_hidden() then
			reply:tag("item", {jid=jid, name=room:get_name()}):up();
		end
	end
end);

local function handle_to_domain(event)
	local origin, stanza = event.origin, event.stanza;
	local type = stanza.attr.type;
	if type == "error" or type == "result" then return; end
	if stanza.name == "iq" and type == "get" then
		local xmlns = stanza.tags[1].attr.xmlns;
		local node = stanza.tags[1].attr.node;
		if xmlns == "http://jabber.org/protocol/muc#unique" then
			origin.send(st.reply(stanza):tag("unique", {xmlns = xmlns}):text(uuid_gen())); -- FIXME Random UUIDs can theoretically have collisions
		else
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- TODO disco/etc
		end
	else
		host_room:handle_stanza(origin, stanza);
		--origin.send(st.error_reply(stanza, "cancel", "service-unavailable", "The muc server doesn't deal with messages and presence directed at it"));
	end
	return true;
end

function stanza_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local bare = jid_bare(stanza.attr.to);
	local room = rooms[bare];
	if not room then
		if stanza.name ~= "presence" then
			origin.send(st.error_reply(stanza, "cancel", "item-not-found"));
			return true;
		end
		if not(restrict_room_creation) or
		  (restrict_room_creation == "admin" and is_admin(stanza.attr.from)) or
		  (restrict_room_creation == "local" and select(2, jid_split(stanza.attr.from)) == module.host:gsub("^[^%.]+%.", "")) then
			room = create_room(bare);
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
	return true;
end
module:hook("iq/bare", stanza_handler, -1);
module:hook("message/bare", stanza_handler, -1);
module:hook("presence/bare", stanza_handler, -1);
module:hook("iq/full", stanza_handler, -1);
module:hook("message/full", stanza_handler, -1);
module:hook("presence/full", stanza_handler, -1);
module:hook("iq/host", handle_to_domain, -1);
module:hook("message/host", handle_to_domain, -1);
module:hook("presence/host", handle_to_domain, -1);

hosts[module.host].send = function(stanza) -- FIXME do a generic fix
	if stanza.attr.type == "result" or stanza.attr.type == "error" then
		module:send(stanza);
	else error("component.send only supports result and error stanzas at the moment"); end
end

hosts[module:get_host()].muc = { rooms = rooms };

local saved = false;
module.save = function()
	saved = true;
	return {rooms = rooms};
end
module.restore = function(data)
	for jid, oldroom in pairs(data.rooms or {}) do
		local room = create_room(jid);
		room._jid_nick = oldroom._jid_nick;
		room._occupants = oldroom._occupants;
		room._data = oldroom._data;
		room._affiliations = oldroom._affiliations;
	end
	hosts[module:get_host()].muc = { rooms = rooms };
end

function shutdown_room(room, stanza)
	for nick, occupant in pairs(room._occupants) do
		stanza.attr.from = nick;
		for jid in pairs(occupant.sessions) do
			stanza.attr.to = jid;
			room:_route_stanza(stanza);
			room._jid_nick[jid] = nil;
		end
		room._occupants[nick] = nil;
	end
end
function shutdown_component()
	if not saved then
		local stanza = st.presence({type = "unavailable"})
			:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
				:tag("item", { affiliation='none', role='none' }):up()
				:tag("status", { code = "332"}):up();
		for roomjid, room in pairs(rooms) do
			shutdown_room(room, stanza);
		end
		shutdown_room(host_room, stanza);
	end
end
module.unload = shutdown_component;
module:hook_global("server-stopping", shutdown_component);

-- Ad-hoc commands
module:depends("adhoc")
local t_concat = table.concat;
local keys = require "util.iterators".keys;
local adhoc_new = module:require "adhoc".new;
local adhoc_initial = require "util.adhoc".new_initial_data_form;
local dataforms_new = require "util.dataforms".new;

local destroy_rooms_layout = dataforms_new {
	title = "Destroy rooms";
	instructions = "Select the rooms to destroy";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/muc#destroy" };
	{ name = "rooms", type = "list-multi", required = true, label = "Rooms to destroy:"};
};

local destroy_rooms_handler = adhoc_initial(destroy_rooms_layout, function()
	return { rooms = array.collect(keys(rooms)):sort() };
end, function(fields, errors)
	if errors then
		local errmsg = {};
		for name, err in pairs(errors) do
			errmsg[#errmsg + 1] = name .. ": " .. err;
		end
		return { status = "completed", error = { message = t_concat(errmsg, "\n") } };
	end
	for _, room in ipairs(fields.rooms) do
		rooms[room]:destroy();
		rooms[room] = nil;
	end
	return { status = "completed", info = "The following rooms were destroyed:\n"..t_concat(fields.rooms, "\n") };
end);
local destroy_rooms_desc = adhoc_new("Destroy Rooms", "http://prosody.im/protocol/muc#destroy", destroy_rooms_handler, "admin");

module:provides("adhoc", destroy_rooms_desc);
