-- Prosody IM
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

--[[
Out of courtesy, a MUC service MAY send an out-of-room <message/>
if a user's affiliation changes while the user is not in the room;
the message SHOULD be sent from the room to the user's bare JID,
MAY contain a <body/> element describing the affiliation change,
and MUST contain a status code of 101.
]]


local st = require "util.stanza";

local function get_affiliation_notify(room)
	return room._data.affiliation_notify;
end

local function set_affiliation_notify(room, affiliation_notify)
	affiliation_notify = affiliation_notify and true or nil;
	if room._data.affiliation_notify == affiliation_notify then return false; end
	room._data.affiliation_notify = affiliation_notify;
	room:save(true);
	return true;
end

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_affiliationnotify";
		type = "boolean";
		label = "Notify users when their affiliation changes when they are not in the room?";
		value = get_affiliation_notify(event.room);
	});
end);

module:hook("muc-config-submitted/muc#roomconfig_affiliationnotify", function(event)
	if set_affiliation_notify(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

module:hook("muc-set-affiliation", function(event)
	local room = event.room;
	if not event.in_room and get_affiliation_notify(room) then
		local body = string.format("Your affiliation in room %s is now %s.", room.jid, event.affiliation);
		local stanza = st.message({
				type = "headline";
				from = room.jid;
				to = event.jid;
			}, body)
			:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
				:tag("status", {code="101"}):up()
			:up();
		room:route_stanza(stanza);
	end
end);

return {
	get = get_affiliation_notify;
	set = set_affiliation_notify;
};
