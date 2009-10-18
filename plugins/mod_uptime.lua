-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

local start_time = prosody.start_time;
prosody.events.add_handler("server-started", function() start_time = prosody.start_time end);

module:add_feature("jabber:iq:last");

module:hook("iq/host/jabber:iq:last:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" then
		origin.send(st.reply(stanza):tag("query", {xmlns = "jabber:iq:last", seconds = tostring(os.difftime(os.time(), start_time))}));
		return true;
	end
end);
