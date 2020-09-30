-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

module:add_feature("urn:xmpp:ping");

local function ping_handler(event)
	event.origin.send(st.reply(event.stanza));
	return true;
end

module:hook("iq-get/bare/urn:xmpp:ping:ping", ping_handler);
module:hook("iq-get/host/urn:xmpp:ping:ping", ping_handler);
