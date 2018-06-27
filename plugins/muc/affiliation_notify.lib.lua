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

module:hook("muc-set-affiliation", function(event)
	local room = event.room;
	if not event.in_room then
		local stanza = st.message({
				type = "headline";
				from = room.jid;
				to = event.jid;
			})
			:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
				:tag("status", {code="101"}):up()
			:up();
		room:route_stanza(stanza);
	end
end);
