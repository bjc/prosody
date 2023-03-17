-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 213/level

local pairs = pairs;
local ipairs = ipairs;
local require = require;
local t_remove = table.remove;

local _ENV = nil;
-- luacheck: std none

local level_sinks = {};

local make_logger;

local function init(name)
	local log_debug = make_logger(name, "debug");
	local log_info = make_logger(name, "info");
	local log_warn = make_logger(name, "warn");
	local log_error = make_logger(name, "error");

	return function (level, message, ...)
			if level == "debug" then
				return log_debug(message, ...);
			elseif level == "info" then
				return log_info(message, ...);
			elseif level == "warn" then
				return log_warn(message, ...);
			elseif level == "error" then
				return log_error(message, ...);
			end
		end
end

function make_logger(source_name, level)
	local level_handlers = level_sinks[level];
	if not level_handlers then
		level_handlers = {};
		level_sinks[level] = level_handlers;
	end

	local logger = function (message, ...)
		for i = 1,#level_handlers do
			level_handlers[i](source_name, level, message, ...);
		end
	end

	return logger;
end

local function reset()
	for level, handler_list in pairs(level_sinks) do
		-- Clear all handlers for this level
		for i = 1, #handler_list do
			handler_list[i] = nil;
		end
	end
end

local function add_level_sink(level, sink_function)
	if not level_sinks[level] then
		level_sinks[level] = { sink_function };
	else
		level_sinks[level][#level_sinks[level] + 1 ] = sink_function;
	end
end

local function add_simple_sink(simple_sink_function, levels)
	local format = require "prosody.util.format".format;
	local function sink_function(name, level, msg, ...)
		return simple_sink_function(name, level, format(msg, ...));
	end
	for _, level in ipairs(levels or {"debug", "info", "warn", "error"}) do
		add_level_sink(level, sink_function);
	end
	return sink_function;
end

local function remove_sink(sink_function)
	local removed;
	for level, sinks in pairs(level_sinks) do
		for i = #sinks, 1, -1 do
			if sinks[i] == sink_function then
				t_remove(sinks, i);
				removed = true;
			end
		end
	end
	return removed;
end

return {
	init = init;
	make_logger = make_logger;
	reset = reset;
	add_level_sink = add_level_sink;
	add_simple_sink = add_simple_sink;
	new = make_logger;
	remove_sink = remove_sink;
};
