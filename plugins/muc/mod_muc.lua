-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

if module:get_host_type() ~= "component" then
	error("MUC should be loaded as a component, please see https://prosody.im/doc/components", 0);
end

local muclib = module:require "muc";
room_mt = muclib.room_mt; -- Yes, global.

local affiliation_notify = module:require "muc/affiliation_notify"; -- luacheck: ignore 211

local name = module:require "muc/name";
room_mt.get_name = name.get;
room_mt.set_name = name.set;

local description = module:require "muc/description";
room_mt.get_description = description.get;
room_mt.set_description = description.set;

local hidden = module:require "muc/hidden";
room_mt.get_hidden = hidden.get;
room_mt.set_hidden = hidden.set;
function room_mt:get_public()
	return not self:get_hidden();
end
function room_mt:set_public(public)
	return self:set_hidden(not public);
end

local password = module:require "muc/password";
room_mt.get_password = password.get;
room_mt.set_password = password.set;

local members_only = module:require "muc/members_only";
room_mt.get_members_only = members_only.get;
room_mt.set_members_only = members_only.set;

local moderated = module:require "muc/moderated";
room_mt.get_moderated = moderated.get;
room_mt.set_moderated = moderated.set;

local persistent = module:require "muc/persistent";
room_mt.get_persistent = persistent.get;
room_mt.set_persistent = persistent.set;

local subject = module:require "muc/subject";
room_mt.get_changesubject = subject.get_changesubject;
room_mt.set_changesubject = subject.set_changesubject;
room_mt.get_subject = subject.get;
room_mt.set_subject = subject.set;
room_mt.send_subject = subject.send;

local history = module:require "muc/history";
room_mt.send_history = history.send;
room_mt.get_historylength = history.get_length;
room_mt.set_historylength = history.set_length;

local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza";
local cache = require "util.cache";
local um_is_admin = require "core.usermanager".is_admin;

module:depends("disco");
module:add_identity("conference", "text", module:get_option_string("name", "Prosody Chatrooms"));
module:add_feature("http://jabber.org/protocol/muc");
module:depends "muc_unique"
module:require "muc/lock";

local function is_admin(jid)
	return um_is_admin(jid, module.host);
end

do -- Monkey patch to make server admins room owners
	local _get_affiliation = room_mt.get_affiliation;
	function room_mt:get_affiliation(jid)
		if is_admin(jid) then return "owner"; end
		return _get_affiliation(self, jid);
	end

	local _set_affiliation = room_mt.set_affiliation;
	function room_mt:set_affiliation(actor, jid, affiliation, reason)
		if affiliation ~= "owner" and is_admin(jid) then return nil, "modify", "not-acceptable"; end
		return _set_affiliation(self, actor, jid, affiliation, reason);
	end
end

local persistent_rooms_storage = module:open_store("persistent");
local persistent_rooms = module:open_store("persistent", "map");
local room_configs = module:open_store("config");

local room_items_cache = {};

local function room_save(room, forced)
	local node = jid_split(room.jid);
	local is_persistent = persistent.get(room);
	room_items_cache[room.jid] = room:get_public() and room:get_name() or nil;
	if is_persistent or forced then
		persistent_rooms:set(nil, room.jid, true);
		local data = room:freeze(forced);
		return room_configs:set(node, data);
	else
		persistent_rooms:set(nil, room.jid, nil);
		return room_configs:set(node, nil);
	end
end

local rooms = cache.new(module:get_option_number("muc_room_cache_size", 100), function (_, room)
	module:log("debug", "%s evicted", room);
	room_save(room, true); -- Force to disk
end);

-- Automatically destroy empty non-persistent rooms
module:hook("muc-occupant-left",function(event)
	local room = event.room
	if not room:has_occupant() and not persistent.get(room) then -- empty, non-persistent room
		module:fire_event("muc-room-destroyed", { room = room });
	end
end);

function track_room(room)
	rooms:set(room.jid, room);
	-- When room is created, over-ride 'save' method
	room.save = room_save;
end

local function restore_room(jid)
	local node = jid_split(jid);
	local data = room_configs:get(node);
	if data then
		local room = muclib.restore_room(data);
		track_room(room);
		return room;
	end
end

function forget_room(room)
	module:log("debug", "Forgetting %s", room);
	rooms.save = nil;
	rooms:set(room.jid, nil);
end

function delete_room(room)
	module:log("debug", "Deleting %s", room);
	room_configs:set(jid_split(room.jid), nil);
	persistent_rooms:set(nil, room.jid, nil);
	room_items_cache[room.jid] = nil;
end

function module.unload()
	for room in rooms:values() do
		room:save(true);
		forget_room(room);
	end
end

function get_room_from_jid(room_jid)
	local room = rooms:get(room_jid);
	if room then
		rooms:set(room_jid, room); -- bump to top;
		return room;
	end
	return restore_room(room_jid);
end

function each_room(local_only)
	if local_only then
		return rooms:values();
	end
	return coroutine.wrap(function ()
		local seen = {}; -- Don't iterate over persistent rooms twice
		for room in rooms:values() do
			coroutine.yield(room);
			seen[room.jid] = true;
		end
		for room_jid in pairs(persistent_rooms_storage:get(nil) or {}) do
			if not seen[room_jid] then
				local room = restore_room(room_jid);
				if room == nil then
					module:log("error", "Missing data for room '%s', omitting from iteration", room_jid);
				else
					coroutine.yield(room);
				end
			end
		end
	end);
end

module:hook("host-disco-items", function(event)
	local reply = event.reply;
	module:log("debug", "host-disco-items called");
	if next(room_items_cache) ~= nil then
		for jid, room_name in pairs(room_items_cache) do
			reply:tag("item", { jid = jid, name = room_name }):up();
		end
	else
		for room in each_room() do
			if not room:get_hidden() then
				local jid, room_name = room.jid, room:get_name();
				room_items_cache[jid] = room_name;
				reply:tag("item", { jid = jid, name = room_name }):up();
			end
		end
	end
end);

module:hook("muc-room-pre-create", function(event)
	track_room(event.room);
end, -1000);

module:hook("muc-room-destroyed",function(event)
	local room = event.room;
	forget_room(room);
	delete_room(room);
end);

do
	local restrict_room_creation = module:get_option("restrict_room_creation");
	if restrict_room_creation == true then
		restrict_room_creation = "admin";
	end
	if restrict_room_creation then
		local host_suffix = module.host:gsub("^[^%.]+%.", "");
		module:hook("muc-room-pre-create", function(event)
			local origin, stanza = event.origin, event.stanza;
			local user_jid = stanza.attr.from;
			if not is_admin(user_jid) and not (
				restrict_room_creation == "local" and
				select(2, jid_split(user_jid)) == host_suffix
			) then
				origin.send(st.error_reply(stanza, "cancel", "not-allowed"));
				return true;
			end
		end);
	end
end

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
		local room_jid = jid_bare(stanza.attr.to);
		local room = get_room_from_jid(room_jid);
		if room == nil then
			-- Watch presence to create rooms
			if stanza.attr.type == nil and stanza.name == "presence" then
				room = muclib.new_room(room_jid);
				return room:handle_first_presence(origin, stanza);
			elseif stanza.attr.type ~= "error" then
				origin.send(st.error_reply(stanza, "cancel", "not-allowed"));
				return true;
			else
				return;
			end
		end
		return room[method](room, origin, stanza);
	end, -2)
end

function shutdown_component()
	for room in each_room(true) do
		room:save(true);
	end
end
module:hook_global("server-stopping", shutdown_component);

do -- Ad-hoc commands
	module:depends "adhoc";
	local t_concat = table.concat;
	local adhoc_new = module:require "adhoc".new;
	local adhoc_initial = require "util.adhoc".new_initial_data_form;
	local array = require "util.array";
	local dataforms_new = require "util.dataforms".new;

	local destroy_rooms_layout = dataforms_new {
		title = "Destroy rooms";
		instructions = "Select the rooms to destroy";

		{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/muc#destroy" };
		{ name = "rooms", type = "list-multi", required = true, label = "Rooms to destroy:"};
	};

	local destroy_rooms_handler = adhoc_initial(destroy_rooms_layout, function()
		return { rooms = array.collect(each_room()):pluck("jid"):sort(); };
	end, function(fields, errors)
		if errors then
			local errmsg = {};
			for field, err in pairs(errors) do
				errmsg[#errmsg + 1] = field .. ": " .. err;
			end
			return { status = "completed", error = { message = t_concat(errmsg, "\n") } };
		end
		for _, room in ipairs(fields.rooms) do
			get_room_from_jid(room):destroy();
		end
		return { status = "completed", info = "The following rooms were destroyed:\n"..t_concat(fields.rooms, "\n") };
	end);
	local destroy_rooms_desc = adhoc_new("Destroy Rooms", "http://prosody.im/protocol/muc#destroy", destroy_rooms_handler, "admin");

	module:provides("adhoc", destroy_rooms_desc);
end
