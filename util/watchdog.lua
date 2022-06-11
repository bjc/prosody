local timer = require "util.timer";
local setmetatable = setmetatable;

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

	watchdog:reset(); -- Kick things off

	return watchdog;
end

function watchdog_methods:reset()
	if self.timer_id then
		timer.reschedule(self.timer_id, self.timeout+1);
	else
		self.timer_id = timer.add_task(self.timeout+1, function ()
			return self:callback();
		end);
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
