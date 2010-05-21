-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";
local datetime = require "util.datetime".datetime;
local legacy = require "util.datetime".legacy;

-- XEP-0202: Entity Time

module:add_feature("urn:xmpp:time");

local function time_handler(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" then
		origin.send(st.reply(stanza):tag("time", {xmlns="urn:xmpp:time"})
			:tag("tzo"):text("+00:00"):up() -- TODO get the timezone in a platform independent fashion
			:tag("utc"):text(datetime()));
		return true;
	end
end

module:hook("iq/bare/urn:xmpp:time:time", time_handler);
module:hook("iq/host/urn:xmpp:time:time", time_handler);

-- XEP-0090: Entity Time (deprecated)

module:add_feature("jabber:iq:time");

local function legacy_time_handler(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" then
		origin.send(st.reply(stanza):tag("query", {xmlns="jabber:iq:time"})
			:tag("utc"):text(legacy()));
		return true;
	end
end

module:hook("iq/bare/jabber:iq:time:query", legacy_time_handler);
module:hook("iq/host/jabber:iq:time:query", legacy_time_handler);
