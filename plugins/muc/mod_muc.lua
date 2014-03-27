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
local lock_rooms = module:get_option_boolean("muc_room_locking", false);
local lock_room_timeout = module:get_option_number("muc_room_lock_timeout", 300);

local muclib = module:require "muc";
local muc_new_room = muclib.new_room;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza";
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
module:depends "muc_unique"

local function is_admin(jid)
	return um_is_admin(jid, module.host);
end

room_mt = muclib.room_mt; -- Yes, global.
local _set_affiliation = room_mt.set_affiliation;
local _get_affiliation = room_mt.get_affiliation;
function muclib.room_mt:get_affiliation(jid)
	if is_admin(jid) then return "owner"; end
	return _get_affiliation(self, jid);
end
function muclib.room_mt:set_affiliation(actor, jid, affiliation, callback, reason)
	if is_admin(jid) then return nil, "modify", "not-acceptable"; end
	return _set_affiliation(self, actor, jid, affiliation, callback, reason);
end

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
	room.save = room_save;
	rooms[jid] = room;
	if lock_rooms then
		room:lock();
		if lock_room_timeout and lock_room_timeout > 0 then
			module:add_timer(lock_room_timeout, function ()
				if room:is_locked() then
					room:destroy(); -- Not unlocked in time
				end
			end);
		end
	end
	module:fire_event("muc-room-created", { room = room });
	return room;
end

function forget_room(jid)
	rooms[jid] = nil;
end

function get_room_from_jid(room_jid)
	return rooms[room_jid]
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
host_room.save = room_save;
rooms[muc_host] = host_room;

module:hook("host-disco-items", function(event)
	local reply = event.reply;
	module:log("debug", "host-disco-items called");
	for jid, room in pairs(rooms) do
		if not room:get_hidden() then
			reply:tag("item", {jid=jid, name=room:get_name()}):up();
		end
	end
end);

module:hook("muc-room-destroyed",function(event)
	local room = event.room
	forget_room(room.jid)
end)

module:hook("muc-occupant-left",function(event)
	local room = event.room
	if not next(room._occupants) and not persistent_rooms[room.jid] then -- empty, non-persistent room
		module:fire_event("muc-room-destroyed", { room = room });
	end
end);

-- Watch presence to create rooms
local function attempt_room_creation(event)
	local origin, stanza = event.origin, event.stanza;
	local room_jid = jid_bare(stanza.attr.to);
	if stanza.attr.type == nil and
		get_room_from_jid(room_jid) == nil and
		(
			not(restrict_room_creation) or
			is_admin(stanza.attr.from) or
			(
				restrict_room_creation == "local" and
				select(2, jid_split(stanza.attr.from)) == module.host:gsub("^[^%.]+%.", "")
			)
		) then
		create_room(room_jid);
	end
end
module:hook("presence/full", attempt_room_creation, -1)
module:hook("presence/bare", attempt_room_creation, -1)
module:hook("presence/host", attempt_room_creation, -1)

for event_name, method in pairs {
	-- Normal room interactions
	["iq-get/bare/http://jabber.org/protocol/disco#info:query"] = "handle_disco_info_get_query" ;
	["iq-get/bare/http://jabber.org/protocol/disco#items:query"] = "handle_disco_items_get_query" ;
	["iq-set/bare/http://jabber.org/protocol/muc#admin:query"] = "handle_admin_query_set_command" ;
	["iq-get/bare/http://jabber.org/protocol/muc#admin:query"] = "handle_admin_query_get_command" ;
	["iq-set/bare/http://jabber.org/protocol/muc#owner:query"] = "handle_owner_query_set_to_room" ;
	["iq-get/bare/http://jabber.org/protocol/muc#owner:query"] = "handle_owner_query_get_to_room" ;
	["message/bare"] = "handle_message_to_room" ;
	["presence/bare"] = "handle_presence_to_room" ;
	-- Host room
	["iq-get/host/http://jabber.org/protocol/disco#info:query"] = "handle_disco_info_get_query" ;
	["iq-get/host/http://jabber.org/protocol/disco#items:query"] = "handle_disco_items_get_query" ;
	["iq-set/host/http://jabber.org/protocol/muc#admin:query"] = "handle_admin_query_set_command" ;
	["iq-get/host/http://jabber.org/protocol/muc#admin:query"] = "handle_admin_query_get_command" ;
	["iq-set/host/http://jabber.org/protocol/muc#owner:query"] = "handle_owner_query_set_to_room" ;
	["iq-get/host/http://jabber.org/protocol/muc#owner:query"] = "handle_owner_query_get_to_room" ;
	["message/host"] = "handle_message_to_room" ;
	["presence/host"] = "handle_presence_to_room" ;
	-- Direct to occupant (normal rooms and host room)
	["presence/full"] = "handle_presence_to_occupant" ;
	["iq/full"] = "handle_iq_to_occupant" ;
	["message/full"] = "handle_message_to_occupant" ;
} do
	module:hook(event_name, function (event)
		local origin, stanza = event.origin, event.stanza;
		local room = get_room_from_jid(jid_bare(stanza.attr.to))
		if room == nil then
			origin.send(st.error_reply(stanza, "cancel", "not-allowed"));
			return true;
		end
		return room[method](room, origin, stanza);
	end, -2)
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

function shutdown_component()
	if not saved then
		local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"})
				:tag("status", { code = "332"}):up();
		for roomjid, room in pairs(rooms) do
			room:clear(x);
		end
		host_room:clear(x);
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
