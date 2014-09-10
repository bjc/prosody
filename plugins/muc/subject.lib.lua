-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

local function create_subject_message(from, subject)
	return st.message({from = from; type = "groupchat"})
		:tag("subject"):text(subject):up();
end

local function get_changesubject(room)
	return room._data.changesubject;
end

local function set_changesubject(room, changesubject)
	changesubject = changesubject and true or nil;
	if get_changesubject(room) == changesubject then return false; end
	room._data.changesubject = changesubject;
	if room.save then room:save(true); end
	return true;
end

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_changesubject";
		type = "boolean";
		label = "Allow Occupants to Change Subject?";
		value = get_changesubject(event.room);
	});
end);

module:hook("muc-config-submitted", function(event)
	local new = event.fields["muc#roomconfig_changesubject"];
	if new ~= nil and set_changesubject(event.room, new) then
		event.status_codes["104"] = true;
	end
end);

local function get_subject(room)
	-- a <message/> stanza from the room JID (or from the occupant JID of the entity that set the subject)
	return room._data.subject_from or room.jid, room._data.subject;
end

local function send_subject(room, to)
	local msg = create_subject_message(get_subject(room));
	msg.attr.to = to;
	room:route_stanza(msg);
end

local function set_subject(room, from, subject)
	if subject == "" then subject = nil; end
	local old_from, old_subject = get_subject(room);
	if old_subject == subject and old_from == from then return false; end
	room._data.subject_from = from;
	room._data.subject = subject;
	if room.save then room:save(); end
	local msg = create_subject_message(from, subject);
	room:broadcast_message(msg);
	return true;
end

-- Send subject to joining user
module:hook("muc-occupant-session-new", function(event)
	send_subject(event.room, event.stanza.attr.from);
end, 20);

-- Role check for subject changes
module:hook("muc-subject-change", function(event)
	local room, stanza = event.room, event.stanza;
	local occupant = room:get_occupant_by_real_jid(stanza.attr.from);
	if occupant.role == "moderator" or
		( occupant.role == "participant" and get_changesubject(room) ) then -- and participant
		local subject = stanza:get_child_text("subject");
		set_subject(room, occupant.nick, subject);
		return true;
	else
		event.origin.send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	end
end);

return {
	get_changesubject = get_changesubject;
	set_changesubject = set_changesubject;
	get = get_subject;
	set = set_subject;
	send = send_subject;
};
