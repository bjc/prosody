local timer = require "util.timer";
local setmetatable = setmetatable;
local os_time = os.time;

local _ENV = nil;
-- luacheck: std none

local watchdog_methods = {};
local watchdog_mt = { __index = watchdog_methods };

local function new(timeout, callback)
	local watchdog = setmetatable({
		timeout = timeout;
		callback = callback;
		timer_id = nil;
	}, watchdog_mt);

	watchdog.timer_id = timer.add_task(timeout+1, function ()
		return watchdog:callback();
	end);

	return watchdog;
end

function watchdog_methods:reset()
	if self.timer_id then
		timer.reschedule(self.timer_id, self.timeout);
	end
end

function watchdog_methods:cancel()
	if self.timer_id then
		timer.stop(self.timer_id);
		self.timer_id = nil;
	end
end

return {
	new = new;
};
