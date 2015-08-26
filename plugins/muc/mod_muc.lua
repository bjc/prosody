-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

if module:get_host_type() ~= "component" then
	error("MUC should be loaded as a component, please see http://prosody.im/doc/components", 0);
end

local muclib = module:require "muc";
room_mt = muclib.room_mt; -- Yes, global.

local affiliation_notify = module:require "muc/affiliation_notify";

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

local iterators = require "util.iterators";
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza";
local um_is_admin = require "core.usermanager".is_admin;

local rooms = module:shared "rooms";

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

local function room_save(room, forced)
	local node = jid_split(room.jid);
	local is_persistent = persistent.get(room);
	persistent_rooms:set(nil, room.jid, is_persistent);
	if is_persistent then
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
end

-- Automatically destroy empty non-persistent rooms
module:hook("muc-occupant-left",function(event)
	local room = event.room
	if not room:has_occupant() and not persistent.get(room) then -- empty, non-persistent room
		module:fire_event("muc-room-destroyed", { room = room });
	end
end);

function track_room(room)
	rooms[room.jid] = room;
	-- When room is created, over-ride 'save' method
	room.save = room_save;
end

local function restore_room(jid)
	local node = jid_split(jid);
	local data = room_configs:get(node);
	if data then
		local room = muclib.new_room(jid);
		room._data = data._data;
		room._affiliations = data._affiliations;
		track_room(room);
		return room;
	end
end

function forget_room(room)
	local room_jid = room.jid;
	local node = jid_split(room.jid);
	rooms[room_jid] = nil;
	room_configs:set(node, nil);
	if persistent.get(room) then
		persistent_rooms:set(nil, room_jid, nil);
	end
end

function get_room_from_jid(room_jid)
	local room = rooms[room_jid];
	if room == nil then
		-- Check if in persistent storage
		if persistent_rooms:get(nil, room_jid) then
			room = restore_room(room_jid);
			if room == nil then
				module:log("error", "Missing data for room '%s', removing from persistent room list", room_jid);
				persistent_rooms:set(nil, room_jid, nil);
			end
		end
	end
	return room
end

function each_room(local_only)
	if not local_only then
		for room_jid in pairs(persistent_rooms_storage:get(nil) or {}) do
			if rooms[room_jid] == nil then -- Don't restore rooms that already exist
				local room = restore_room(room_jid);
				if room == nil then
					module:log("error", "Missing data for room '%s', omitting from iteration", room_jid);
				end
			end
		end
	end
	return iterators.values(rooms);
end

module:hook("host-disco-items", function(event)
	local reply = event.reply;
	module:log("debug", "host-disco-items called");
	for room in each_room() do
		if not room:get_hidden() then
			reply:tag("item", {jid=room.jid, name=room:get_name()}):up();
		end
	end
end);

module:hook("muc-room-pre-create", function(event)
	track_room(event.room);
end, -1000);

module:hook("muc-room-destroyed",function(event)
	return forget_room(event.room);
end)

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
			else
				origin.send(st.error_reply(stanza, "cancel", "not-allowed"));
				return true;
			end
		end
		return room[method](room, origin, stanza);
	end, -2)
end

function shutdown_component()
	local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"})
		:tag("status", { code = "332"}):up();
	for room in each_room(true) do
		room:clear(x);
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
			for name, err in pairs(errors) do
				errmsg[#errmsg + 1] = name .. ": " .. err;
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
