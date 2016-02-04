-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local pairs = pairs;

local _ENV = nil;

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

return {
	init = init;
	make_logger = make_logger;
	reset = reset;
	add_level_sink = add_level_sink;
	new = make_logger;
};
