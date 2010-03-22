-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module("helpers", package.seeall);

-- Helper functions for debugging

local log = require "util.logger".init("util.debug");

function log_events(events, name, logger)
	local f = events.fire_event;
	if not f then
		error("Object does not appear to be a util.events object");
	end
	logger = logger or log;
	name = name or tostring(events);
	function events.fire_event(event, ...)
		logger("debug", "%s firing event: %s", name, event);
		return f(event, ...);
	end
	events[events.fire_event] = f;
	return events;
end

function revert_log_events(events)
	events.fire_event, events[events.fire_event] = events[events.fire_event], nil; -- :)
end

function get_upvalue(f, get_name)
	local i, name, value = 0;
	repeat
		i = i + 1;
		name, value = debug.getupvalue(f, i);
	until name == get_name or name == nil;
	return value;
end

return _M;
