-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "prosody.util.stanza";
local datetime = require "prosody.util.datetime".datetime;
local now = require "prosody.util.time".now;

-- XEP-0202: Entity Time

module:add_feature("urn:xmpp:time");

local function time_handler(event)
	local origin, stanza = event.origin, event.stanza;
	origin.send(st.reply(stanza):tag("time", {xmlns="urn:xmpp:time"})
		:tag("tzo"):text("+00:00"):up() -- TODO get the timezone in a platform independent fashion
		:tag("utc"):text(datetime(now())));
	return true;
end

module:hook("iq-get/bare/urn:xmpp:time:time", time_handler);
module:hook("iq-get/host/urn:xmpp:time:time", time_handler);

