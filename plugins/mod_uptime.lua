-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "prosody.util.stanza";

local start_time = prosody.start_time;
module:hook_global("server-started", function() start_time = prosody.start_time end);

-- XEP-0012: Last activity
module:add_feature("jabber:iq:last");

module:hook("iq-get/host/jabber:iq:last:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	origin.send(st.reply(stanza):tag("query", {xmlns = "jabber:iq:last", seconds = tostring(("%d"):format(os.difftime(os.time(), start_time)))}));
	return true;
end);

-- Ad-hoc command
module:depends "adhoc";
local adhoc_new = module:require "adhoc".new;

function uptime_text()
	local t = os.time()-prosody.start_time;
	local seconds = t%60;
	t = (t - seconds)/60;
	local minutes = t%60;
	t = (t - minutes)/60;
	local hours = t%24;
	t = (t - hours)/24;
	local days = t;
	return string.format("This server has been running for %d day%s, %d hour%s and %d minute%s (since %s)",
		days, (days ~= 1 and "s") or "", hours, (hours ~= 1 and "s") or "",
		minutes, (minutes ~= 1 and "s") or "", os.date("%c", prosody.start_time));
end

function uptime_command_handler ()
	return { info = uptime_text(), status = "completed" };
end

local descriptor = adhoc_new("Get uptime", "uptime", uptime_command_handler, "any");

module:provides("adhoc", descriptor);
