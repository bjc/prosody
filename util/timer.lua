-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local indexedbheap = require "util.indexedbheap";
local log = require "util.logger".init("timer");
local server = require "net.server";
local math_min = math.min
local math_huge = math.huge
local get_time = require "socket".gettime;
local t_insert = table.insert;
local pairs = pairs;
local type = type;
local debug_traceback = debug.traceback;
local tostring = tostring;
local xpcall = xpcall;

local data = {};
local new_data = {};

module "timer"

local _add_task;
if not server.event then
	function _add_task(delay, callback)
		local current_time = get_time();
		delay = delay + current_time;
		if delay >= current_time then
			t_insert(new_data, {delay, callback});
		else
			local r = callback(current_time);
			if r and type(r) == "number" then
				return _add_task(r, callback);
			end
		end
	end

	server._addtimer(function()
		local current_time = get_time();
		if #new_data > 0 then
			for _, d in pairs(new_data) do
				t_insert(data, d);
			end
			new_data = {};
		end

		local next_time = math_huge;
		for i, d in pairs(data) do
			local t, callback = d[1], d[2];
			if t <= current_time then
				data[i] = nil;
				local r = callback(current_time);
				if type(r) == "number" then
					_add_task(r, callback);
					next_time = math_min(next_time, r);
				end
			else
				next_time = math_min(next_time, t - current_time);
			end
		end
		return next_time;
	end);
else
	local event = server.event;
	local event_base = server.event_base;
	local EVENT_LEAVE = (event.core and event.core.LEAVE) or -1;

	function _add_task(delay, callback)
		local event_handle;
		event_handle = event_base:addevent(nil, 0, function ()
			local ret = callback(get_time());
			if ret then
				return 0, ret;
			elseif event_handle then
				return EVENT_LEAVE;
			end
		end
		, delay);
	end
end

--add_task = _add_task;

local h = indexedbheap.create();
local params = {};
local next_time = nil;
local _id, _callback, _now, _param;
local function _call() return _callback(_now, _id, _param); end
local function _traceback_handler(err) log("error", "Traceback[timer]: %s", debug_traceback(tostring(err), 2)); end
local function _on_timer(now)
	local peek;
	while true do
		peek = h:peek();
		if peek == nil or peek > now then break; end
		local _;
		_, _callback, _id = h:pop();
		_now = now;
		_param = params[_id];
		params[_id] = nil;
		--item(now, id, _param); -- FIXME pcall
		local success, err = xpcall(_call, _traceback_handler);
		if success and type(err) == "number" then
			h:insert(_callback, err + now, _id); -- re-add
		end
	end
	next_time = peek;
	if peek ~= nil then
		return peek - now;
	end
end
function add_task(delay, callback, param)
	local current_time = get_time();
	local event_time = current_time + delay;

	local id = h:insert(callback, event_time);
	params[id] = param;
	if next_time == nil or event_time < next_time then
		next_time = event_time;
		_add_task(next_time - current_time, _on_timer);
	end
	return id;
end
function stop(id)
	params[id] = nil;
	return h:remove(id);
end
function reschedule(id, delay)
	local current_time = get_time();
	local event_time = current_time + delay;
	h:reprioritize(id, delay);
	if next_time == nil or event_time < next_time then
		next_time = event_time;
		_add_task(next_time - current_time, _on_timer);
	end
	return id;
end

return _M;
