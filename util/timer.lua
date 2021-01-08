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
local get_time = require "util.time".now
local type = type;
local debug_traceback = debug.traceback;
local tostring = tostring;
local xpcall = require "util.xpcall".xpcall;
local math_max = math.max;
local pairs = pairs;

if server.timer then
	-- The selected net.server implements this API, so defer to that
	return server.timer;
end

local _ENV = nil;
-- luacheck: std none

local _add_task = server.add_task;

local _server_timer;
local _active_timers = 0;
local h = indexedbheap.create();
local params = {};
local next_time = nil;
local function _traceback_handler(err) log("error", "Traceback[timer]: %s", debug_traceback(tostring(err), 2)); end
local function _on_timer(now)
	local peek;
	local readd;
	while true do
		peek = h:peek();
		if peek == nil or peek > now then break; end
		local _, callback, id = h:pop();
		local param = params[id];
		params[id] = nil;
		--item(now, id, _param);
		local success, err = xpcall(callback, _traceback_handler, now, id, param);
		if success and type(err) == "number" then
			if readd then
				readd[id] = { callback, err + now };
			else
				readd = { [id] = { callback, err + now } };
			end
			params[id] = param;
		end
	end

	if readd then
		for id,timer in pairs(readd) do
			h:insert(timer[1], timer[2], id);
		end
		peek = h:peek();
	end

	if peek ~= nil and _active_timers > 1 and peek == next_time then
		-- Another instance of _on_timer already set next_time to the same value,
		-- so it should be safe to not renew this timer event
		peek = nil;
	else
		next_time = peek;
	end

	if peek then
		-- peek is the time of the next event
		return peek - now;
	end
	_active_timers = _active_timers - 1;
end
local function add_task(delay, callback, param)
	local current_time = get_time();
	local event_time = current_time + delay;

	local id = h:insert(callback, event_time);
	params[id] = param;
	if next_time == nil or event_time < next_time then
		next_time = event_time;
		if _server_timer then
			_server_timer:close();
			_server_timer = nil;
		else
			_active_timers = _active_timers + 1;
		end
		_server_timer = _add_task(next_time - current_time, _on_timer);
	end
	return id;
end
local function stop(id)
	params[id] = nil;
	local result, item, result_sync = h:remove(id);
	local peek = h:peek();
	if peek ~= next_time and _server_timer then
		next_time = peek;
		_server_timer:close();
		if next_time ~= nil then
			_server_timer = _add_task(math_max(next_time - get_time(), 0), _on_timer);
		end
	end
	return result, item, result_sync;
end
local function reschedule(id, delay)
	local current_time = get_time();
	local event_time = current_time + delay;
	h:reprioritize(id, delay);
	if next_time == nil or event_time < next_time then
		next_time = event_time;
		_add_task(next_time - current_time, _on_timer);
	end
	return id;
end

return {
	add_task = add_task;
	stop = stop;
	reschedule = reschedule;
};

