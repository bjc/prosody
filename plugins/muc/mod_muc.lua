-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

-- Exposed functions:
--
-- create_room(jid) -> room
-- track_room(room)
-- delete_room(room)
-- forget_room(room)
-- get_room_from_jid(jid) -> room
-- each_room(live_only) -> () -> room [DEPRECATED]
-- all_rooms() -> room
-- live_rooms() -> room
-- shutdown_component()

if module:get_host_type() ~= "component" then
	error("MUC should be loaded as a component, please see https://prosody.im/doc/components", 0);
end

local muclib = module:require "muc";
room_mt = muclib.room_mt; -- Yes, global.
new_room = muclib.new_room;

local name = module:require "muc/name";
room_mt.get_name = name.get;
room_mt.set_name = name.set;

local description = module:require "muc/description";
room_mt.get_description = description.get;
room_mt.set_description = description.set;

local language = module:require "muc/language";
room_mt.get_language = language.get;
room_mt.set_language = language.set;

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
room_mt.get_allow_member_invites = members_only.get_allow_member_invites;
room_mt.set_allow_member_invites = members_only.set_allow_member_invites;

local moderated = module:require "muc/moderated";
room_mt.get_moderated = moderated.get;
room_mt.set_moderated = moderated.set;

local request = module:require "muc/request";
room_mt.handle_role_request = request.handle_request;

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

local register = module:require "muc/register";
room_mt.get_registered_nick = register.get_registered_nick;
room_mt.get_registered_jid = register.get_registered_jid;
room_mt.handle_register_iq = register.handle_register_iq;

local presence_broadcast = module:require "muc/presence_broadcast";
room_mt.get_presence_broadcast = presence_broadcast.get;
room_mt.set_presence_broadcast = presence_broadcast.set;
room_mt.get_valid_broadcast_roles = presence_broadcast.get_valid_broadcast_roles; -- FIXME doesn't exist in the library

local occupant_id = module:require "muc/occupant_id";
room_mt.get_salt = occupant_id.get_room_salt;
room_mt.get_occupant_id = occupant_id.get_occupant_id;

local jid_split = require "prosody.util.jid".split;
local jid_prep = require "prosody.util.jid".prep;
local jid_bare = require "prosody.util.jid".bare;
local st = require "prosody.util.stanza";
local cache = require "prosody.util.cache";

module:require "muc/config_form_sections";

module:depends("disco");
module:add_identity("conference", "text", module:get_option_string("name", "Prosody Chatrooms"));
module:add_feature("http://jabber.org/protocol/muc");
module:depends "muc_unique"
module:require "muc/hats";
module:require "muc/lock";

module:default_permissions("prosody:admin", {
	":automatic-ownership";
	":create-room";
	":recreate-destroyed-room";
});

if module:get_option_boolean("component_admins_as_room_owners", true) then
	-- Monkey patch to make server admins room owners
	local _get_affiliation = room_mt.get_affiliation;
	function room_mt:get_affiliation(jid)
		if module:may(":automatic-ownership", jid) then return "owner"; end
		return _get_affiliation(self, jid);
	end

	local _set_affiliation = room_mt.set_affiliation;
	function room_mt:set_affiliation(actor, jid, affiliation, reason, data)
		if affiliation ~= "owner" and module:may(":automatic-ownership", jid) then return nil, "modify", "not-acceptable"; end
		return _set_affiliation(self, actor, jid, affiliation, reason, data);
	end
end

local persistent_rooms_storage = module:open_store("persistent");
local persistent_rooms = module:open_store("persistent", "map");
local room_configs = module:open_store("config");
local room_state = module:open_store("state");

local room_items_cache = {};

local function room_save(room, forced, savestate)
	local node = jid_split(room.jid);
	local is_persistent = persistent.get(room);
	if room:get_public() then
		room_items_cache[room.jid] = room:get_name() or "";
	else
		room_items_cache[room.jid] = nil;
	end

	if is_persistent or savestate then
		persistent_rooms:set(nil, room.jid, true);
		local data, state = room:freeze(savestate);
		room_state:set(node, state);
		return room_configs:set(node, data);
	elseif forced then
		persistent_rooms:set(nil, room.jid, nil);
		room_state:set(node, nil);
		return room_configs:set(node, nil);
	end
end

local max_rooms = module:get_option_number("muc_max_rooms");
local max_live_rooms = module:get_option_number("muc_room_cache_size", 100);

local room_hit = module:measure("room_hit", "rate");
local room_miss = module:measure("room_miss", "rate")
local room_eviction = module:measure("room_eviction", "rate");
local rooms = cache.new(max_rooms or max_live_rooms, function (jid, room)
	if max_rooms then
		module:log("info", "Room limit of %d reached, no new rooms allowed", max_rooms);
		return false;
	end
	module:log("debug", "Evicting room %s", jid);
	room_eviction();
	if room:get_public() then
		room_items_cache[room.jid] = room:get_name() or "";
	else
		room_items_cache[room.jid] = nil;
	end
	local ok, err = room_save(room, nil, true); -- Force to disk
	if not ok then
		module:log("error", "Failed to swap inactive room %s to disk: %s", jid, err);
		return false;
	end
end);

local measure_rooms_size = module:measure("live_room", "amount");
module:hook_global("stats-update", function ()
	measure_rooms_size(rooms:count());
end);

-- Automatically destroy empty non-persistent rooms
module:hook("muc-occupant-left",function(event)
	local room = event.room
	if room.destroying then return end
	if not room:has_occupant() and not persistent.get(room) then -- empty, non-persistent room
		module:log("debug", "%q empty, destroying", room.jid);
		module:fire_event("muc-room-destroyed", { room = room });
	end
end, -1);

function track_room(room)
	if rooms:set(room.jid, room) then
		-- When room is created, over-ride 'save' method
		room.save = room_save;
		return room;
	end
	-- Resource limit reached
	return false;
end

local function handle_broken_room(room, origin, stanza)
	module:log("debug", "Returning error from broken room %s", room.jid);
	origin.send(st.error_reply(stanza, "wait", "internal-server-error", nil, room.jid));
	return true;
end

local function restore_room(jid)
	local node = jid_split(jid);
	local data, err = room_configs:get(node);
	if data then
		module:log("debug", "Restoring room %s from storage", jid);
		if module:fire_event("muc-room-pre-restore", { jid = jid, data = data }) == false then
			return false;
		end
		local state, s_err = room_state:get(node);
		if not state and s_err then
			module:log("debug", "Could not restore state of room %s: %s", jid, s_err);
		end
		local room = muclib.restore_room(data, state);
		if track_room(room) then
			room_state:set(node, nil);
			module:fire_event("muc-room-restored", { jid = jid, room = room });
			return room;
		else
			return false;
		end
	elseif err then
		module:log("error", "Error restoring room %s from storage: %s", jid, err);
		local room = muclib.new_room(jid, { locked = math.huge });
		room.handle_normal_presence = handle_broken_room;
		room.handle_first_presence = handle_broken_room;
		return room;
	end
end

-- Removes a room from memory, without saving it (save first if required)
function forget_room(room)
	module:log("debug", "Forgetting %s", room.jid);
	rooms.save = nil;
	rooms:set(room.jid, nil);
end

-- Removes a room from the database (may remain in memory)
function delete_room(room)
	module:log("debug", "Deleting %s", room.jid);
	room_configs:set(jid_split(room.jid), nil);
	room_state:set(jid_split(room.jid), nil);
	persistent_rooms:set(nil, room.jid, nil);
	room_items_cache[room.jid] = nil;
end

function module.unload()
	for room in live_rooms() do
		room:save(nil, true);
		forget_room(room);
	end
end

function get_room_from_jid(room_jid)
	local room = rooms:get(room_jid);
	if room then
		room_hit();
		rooms:set(room_jid, room); -- bump to top;
		return room;
	end
	room_miss();
	return restore_room(room_jid);
end

local function set_room_defaults(room, lang)
	room:set_public(module:get_option_boolean("muc_room_default_public", false));
	room:set_persistent(module:get_option_boolean("muc_room_default_persistent", room:get_persistent()));
	room:set_members_only(module:get_option_boolean("muc_room_default_members_only", room:get_members_only()));
	room:set_allow_member_invites(module:get_option_boolean("muc_room_default_allow_member_invites",
		room:get_allow_member_invites()));
	room:set_moderated(module:get_option_boolean("muc_room_default_moderated", room:get_moderated()));
	room:set_whois(module:get_option_boolean("muc_room_default_public_jids",
		room:get_whois() == "anyone") and "anyone" or "moderators");
	room:set_changesubject(module:get_option_boolean("muc_room_default_change_subject", room:get_changesubject()));
	room:set_historylength(module:get_option_number("muc_room_default_history_length", room:get_historylength()));
	room:set_language(lang or module:get_option_string("muc_room_default_language"));
	room:set_presence_broadcast(module:get_option("muc_room_default_presence_broadcast", room:get_presence_broadcast()));
end

function create_room(room_jid, config)
	if jid_bare(room_jid) ~= room_jid or not jid_prep(room_jid, true) then
		return nil, "invalid-jid";
	end
	local exists = get_room_from_jid(room_jid);
	if exists then
		return nil, "room-exists";
	end
	local room = muclib.new_room(room_jid, config);
	if not config then
		set_room_defaults(room);
	end
	module:fire_event("muc-room-created", {
		room = room;
	});
	return track_room(room);
end

function all_rooms()
	return coroutine.wrap(function ()
		local seen = {}; -- Don't iterate over persistent rooms twice
		for room in live_rooms() do
			coroutine.yield(room);
			seen[room.jid] = true;
		end
		local all_persistent_rooms, err = persistent_rooms_storage:get(nil);
		if not all_persistent_rooms then
			if err then
				module:log("error", "Error loading list of persistent rooms, only rooms live in memory were iterated over");
				module:log("debug", "%s", debug.traceback(err));
			end
			return nil;
		end
		for room_jid in pairs(all_persistent_rooms) do
			if not seen[room_jid] then
				local room = restore_room(room_jid);
				if room then
					coroutine.yield(room);
				else
					module:log("error", "Missing data for room '%s', omitting from iteration", room_jid);
				end
			end
		end
	end);
end

function live_rooms()
	return rooms:values();
end

function each_room(live_only)
	if live_only then
		return live_rooms();
	end
	return all_rooms();
end

module:hook("host-disco-items", function(event)
	local reply = event.reply;
	module:log("debug", "host-disco-items called");
	if next(room_items_cache) ~= nil then
		for jid, room_name in pairs(room_items_cache) do
			if room_name == "" then room_name = nil; end
			reply:tag("item", { jid = jid, name = room_name }):up();
		end
	else
		for room in all_rooms() do
			if not room:get_hidden() then
				local jid, room_name = room.jid, room:get_name();
				room_items_cache[jid] = room_name or "";
				reply:tag("item", { jid = jid, name = room_name }):up();
			end
		end
	end
end);

module:hook("muc-room-pre-create", function (event)
	set_room_defaults(event.room, event.stanza.attr["xml:lang"]);
end, 1);

module:hook("muc-room-pre-create", function(event)
	local origin, stanza = event.origin, event.stanza;
	if not track_room(event.room) then
		origin.send(st.error_reply(stanza, "wait", "resource-constraint", nil, module.host));
		return true;
	end
end, -1000);

module:hook("muc-room-destroyed",function(event)
	local room = event.room;
	forget_room(room);
	delete_room(room);
end);

if module:get_option_boolean("muc_tombstones", true) then

	local ttl = module:get_option_number("muc_tombstone_expiry", 86400 * 31);

	module:hook("muc-room-destroyed",function(event)
		local room = event.room;
		if not room:get_persistent() then return end
		if room._data.destroyed then
			return -- Allow destruction of tombstone
		end

		local tombstone = new_room(room.jid, {
			locked = os.time() + ttl;
			destroyed = true;
			reason = event.reason;
			newjid = event.newjid;
			-- password?
		});
		tombstone.save = room_save;
		tombstone:set_persistent(true);
		tombstone:set_hidden(true);
		tombstone:save(true);
		return true;
	end, -10);
end

local restrict_room_creation = module:get_option("restrict_room_creation");
module:default_permission(restrict_room_creation == true and "prosody:admin" or "prosody:registered", ":create-room");
module:hook("muc-room-pre-create", function(event)
	local origin, stanza = event.origin, event.stanza;
	if restrict_room_creation ~= false and not module:may(":create-room", event) then
		origin.send(st.error_reply(stanza, "cancel", "not-allowed", "Room creation is restricted", module.host));
		return true;
	end
end);

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
	["iq/bare/jabber:iq:register:query"] = "handle_register_iq";
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

		if room and room._data.destroyed then
			if room._data.locked < os.time()
			or (module:may(":recreate-destroyed-room", event) and stanza.name == "presence" and stanza.attr.type == nil) then
				-- Allow the room to be recreated by admin or after time has passed
				delete_room(room);
				room = nil;
			else
				if stanza.attr.type ~= "error" then
					local reply = st.error_reply(stanza, "cancel", "gone", room._data.reason, module.host)
					if room._data.newjid then
						local uri = "xmpp:"..room._data.newjid.."?join";
						reply:get_child("error"):child_with_name("gone"):text(uri);
					end
					event.origin.send(reply);
				end
				return true;
			end
		end

		if room == nil then
			-- Watch presence to create rooms
			if not jid_prep(room_jid, true) then
				origin.send(st.error_reply(stanza, "modify", "jid-malformed", nil, module.host));
				return true;
			end
			if stanza.attr.type == nil and stanza.name == "presence" and stanza:get_child("x", "http://jabber.org/protocol/muc") then
				room = muclib.new_room(room_jid);
				return room:handle_first_presence(origin, stanza);
			elseif stanza.attr.type ~= "error" then
				origin.send(st.error_reply(stanza, "cancel", "item-not-found", nil, module.host));
				return true;
			else
				return;
			end
		elseif room == false then -- Error loading room
			origin.send(st.error_reply(stanza, "wait", "resource-constraint", nil, module.host));
			return true;
		end
		return room[method](room, origin, stanza);
	end, -2)
end

function shutdown_component()
	for room in live_rooms() do
		room:save(nil, true);
	end
end
module:hook_global("server-stopping", shutdown_component, -300);

do -- Ad-hoc commands
	module:depends "adhoc";
	local t_concat = table.concat;
	local adhoc_new = module:require "adhoc".new;
	local adhoc_initial = require "prosody.util.adhoc".new_initial_data_form;
	local adhoc_simple = require "prosody.util.adhoc".new_simple_form;
	local array = require "prosody.util.array";
	local dataforms_new = require "prosody.util.dataforms".new;

	local destroy_rooms_layout = dataforms_new {
		title = "Destroy rooms";
		instructions = "Select the rooms to destroy";

		{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/muc#destroy" };
		{ name = "rooms", type = "list-multi", required = true, label = "Rooms to destroy:"};
	};

	local destroy_rooms_handler = adhoc_initial(destroy_rooms_layout, function()
		return { rooms = array.collect(all_rooms()):pluck("jid"):sort(); };
	end, function(fields, errors)
		if errors then
			local errmsg = {};
			for field, err in pairs(errors) do
				errmsg[#errmsg + 1] = field .. ": " .. err;
			end
			return { status = "completed", error = { message = t_concat(errmsg, "\n") } };
		end
		local destroyed = array();
		for _, room_jid in ipairs(fields.rooms) do
			local room = get_room_from_jid(room_jid);
			if room and room:destroy() then
				destroyed:push(room.jid);
			end
		end
		return { status = "completed", info = "The following rooms were destroyed:\n"..t_concat(destroyed, "\n") };
	end);
	local destroy_rooms_desc = adhoc_new("Destroy Rooms",
		"http://prosody.im/protocol/muc#destroy", destroy_rooms_handler, "admin");

	module:provides("adhoc", destroy_rooms_desc);


	local set_affiliation_layout = dataforms_new {
		-- FIXME wordsmith title, instructions, labels etc
		title = "Set affiliation";

		{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/muc#set-affiliation" };
		{ name = "room", type = "jid-single", required = true, label = "Room"};
		{ name = "jid", type = "jid-single", required = true, label = "JID"};
		{ name = "affiliation", type = "list-single", required = true, label = "Affiliation",
			options = { "owner"; "admin"; "member"; "none"; "outcast"; },
		};
		{ name = "reason", type = "text-single", "Reason", }
	};

	local set_affiliation_handler = adhoc_simple(set_affiliation_layout, function (fields, errors)
		if errors then
			local errmsg = {};
			for field, err in pairs(errors) do
				errmsg[#errmsg + 1] = field .. ": " .. err;
			end
			return { status = "completed", error = { message = t_concat(errmsg, "\n") } };
		end

		local room = get_room_from_jid(fields.room);
		if not room then
			return { status = "canceled", error = { message =  "No such room"; }; };
		end
		local ok, err, condition = room:set_affiliation(true, fields.jid, fields.affiliation, fields.reason);

		if not ok then
			return { status = "canceled", error = { message =  "Affiliation change failed: "..err..":"..condition; }; };
		end

		return { status = "completed", info = "Affiliation updated",
		};
	end);

	local set_affiliation_desc = adhoc_new("Set affiliation in room",
		"http://prosody.im/protocol/muc#set-affiliation", set_affiliation_handler, "admin");

	module:provides("adhoc", set_affiliation_desc);
end
