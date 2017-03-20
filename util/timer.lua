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
local xpcall = xpcall;

local _ENV = nil;

local _add_task = server.add_task;

local _server_timer;
local _active_timers = 0;
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
			params[_id] = _param;
		end
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
			_server_timer = _add_task(next_time - get_time(), _on_timer);
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

