-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

module:add_feature("urn:xmpp:ping");

local function ping_handler(event)
	if event.stanza.attr.type == "get" then
		event.origin.send(st.reply(event.stanza));
		return true;
	end
end

module:hook("iq/bare/urn:xmpp:ping:ping", ping_handler);
module:hook("iq/host/urn:xmpp:ping:ping", ping_handler);
