-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local ns_addtimer = require "net.server".addtimer;
local event = require "net.server".event;
local event_base = require "net.server".event_base;

local math_min = math.min
local math_huge = math.huge
local get_time = require "socket".gettime;
local t_insert = table.insert;
local t_remove = table.remove;
local ipairs, pairs = ipairs, pairs;
local type = type;

local data = {};
local new_data = {};

module "timer"

local _add_task;
if not event then
	function _add_task(delay, func)
		local current_time = get_time();
		delay = delay + current_time;
		if delay >= current_time then
			t_insert(new_data, {delay, func});
		else
			func();
		end
	end

	ns_addtimer(function()
		local current_time = get_time();
		if #new_data > 0 then
			for _, d in pairs(new_data) do
				t_insert(data, d);
			end
			new_data = {};
		end
		
		local next_time = math_huge;
		for i, d in pairs(data) do
			local t, func = d[1], d[2];
			if t <= current_time then
				data[i] = nil;
				local r = func(current_time);
				if type(r) == "number" then
					_add_task(r, func);
					next_time = math_min(next_time, r);
				end
			else
				next_time = math_min(next_time, t - current_time);
			end
		end
		return next_time;
	end);
else
	local EVENT_LEAVE = (event.core and event.core.LEAVE) or -1;
	function _add_task(delay, func)
		local event_handle;
		event_handle = event_base:addevent(nil, 0, function ()
			local ret = func();
			if ret then
				return 0, ret;
			elseif event_handle then
				return EVENT_LEAVE;
			end
		end
		, delay);
	end
end

add_task = _add_task;

return _M;
