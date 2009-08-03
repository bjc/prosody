
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
	end
	events[events.fire_event] = f;
	return events;
end

function revert_log_events(events)
	events.fire_event, events[events.fire_event] = events[events.fire_event], nil; -- :)
end

return _M;
