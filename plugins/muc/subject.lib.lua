-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";
local dt = require "util.datetime";

local muc_util = module:require "muc/util";
local valid_roles = muc_util.valid_roles;

local function create_subject_message(from, subject)
	return st.message({from = from; type = "groupchat"})
		:tag("subject"):text(subject or ""):up();
end

local function get_changesubject(room)
	return room._data.changesubject;
end

local function set_changesubject(room, changesubject)
	changesubject = changesubject and true or nil;
	if get_changesubject(room) == changesubject then return false; end
	room._data.changesubject = changesubject;
	return true;
end

module:hook("muc-disco#info", function (event)
	table.insert(event.form, {
		name = "muc#roomconfig_changesubject";
		type = "boolean";
	});
	event.formdata["muc#roomconfig_changesubject"] = get_changesubject(event.room);
end);

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_changesubject";
		type = "boolean";
		label = "Allow anyone to set the room's subject";
		desc = "Choose whether anyone, or only moderators, may set the room's subject";
		value = get_changesubject(event.room);
	});
end, 80-1);

module:hook("muc-config-submitted/muc#roomconfig_changesubject", function(event)
	if set_changesubject(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

local function get_subject(room)
	-- a <message/> stanza from the room JID (or from the occupant JID of the entity that set the subject)
	return room._data.subject_from or room.jid, room._data.subject;
end

local function send_subject(room, to, time)
	local msg = create_subject_message(get_subject(room));
	msg.attr.to = to;
	if time then
		msg:tag("delay", {
			xmlns = "urn:xmpp:delay",
			from = room.jid,
			stamp = dt.datetime(time);
		}):up();
	end
	room:route_stanza(msg);
end

local function set_subject(room, from, subject)
	if subject == "" then subject = nil; end
	local old_from, old_subject = get_subject(room);
	if old_subject == subject and old_from == from then return false; end
	room._data.subject_from = from;
	room._data.subject = subject;
	room._data.subject_time = os.time();
	local msg = create_subject_message(from, subject);
	room:broadcast_message(msg);
	return true;
end

-- Send subject to joining user
module:hook("muc-occupant-session-new", function(event)
	send_subject(event.room, event.stanza.attr.from, event.room._data.subject_time);
end, 20);

-- Prosody has made the decision that messages with <subject/> are exclusively subject changes
-- e.g. body will be ignored; even if the subject change was not allowed
module:hook("muc-occupant-groupchat", function(event)
	local stanza = event.stanza;
	local subject = stanza:get_child("subject");
	if subject then
		local room = event.room;
		local occupant = event.occupant;
		-- Role check for subject changes
		local role_rank = valid_roles[occupant and occupant.role or "none"];
		if role_rank >= valid_roles.moderator or
			( role_rank >= valid_roles.participant and get_changesubject(room) ) then -- and participant
			set_subject(room, occupant.nick, subject:get_text());
			room:save();
			return true;
		else
			event.origin.send(st.error_reply(stanza, "auth", "forbidden", "You are not allowed to change the subject"));
			return true;
		end
	end
end, 20);

return {
	get_changesubject = get_changesubject;
	set_changesubject = set_changesubject;
	get = get_subject;
	set = set_subject;
	send = send_subject;
};
