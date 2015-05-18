-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local format = string.format;
local setmetatable, rawset, pairs, ipairs, type =
	setmetatable, rawset, pairs, ipairs, type;
local io_open, io_write = io.open, io.write;
local math_max, rep = math.max, string.rep;
local os_date = os.date;
local getstyle, setstyle = require "util.termcolours".getstyle, require "util.termcolours".setstyle;

if os.getenv("__FLUSH_LOG") then
	local io_flush = io.flush;
	local _io_write = io_write;
	io_write = function(...) _io_write(...); io_flush(); end
end

local config = require "core.configmanager";
local logger = require "util.logger";
local prosody = prosody;

_G.log = logger.init("general");

module "loggingmanager"

-- The log config used if none specified in the config file (see reload_logging for initialization)
local default_logging;
local default_file_logging;
local default_timestamp = "%b %d %H:%M:%S";
-- The actual config loggingmanager is using
local logging_config;

local apply_sink_rules;
local log_sink_types = setmetatable({}, { __newindex = function (t, k, v) rawset(t, k, v); apply_sink_rules(k); end; });
local get_levels;
local logging_levels = { "debug", "info", "warn", "error" }

-- Put a rule into action. Requires that the sink type has already been registered.
-- This function is called automatically when a new sink type is added [see apply_sink_rules()]
local function add_rule(sink_config)
	local sink_maker = log_sink_types[sink_config.to];
	if not sink_maker then
		return; -- No such sink type
	end

	-- Create sink
	local sink = sink_maker(sink_config);

	-- Set sink for all chosen levels
	for level in pairs(get_levels(sink_config.levels or logging_levels)) do
		logger.add_level_sink(level, sink);
	end
end

-- Search for all rules using a particular sink type, and apply
-- them. Called automatically when a new sink type is added to
-- the log_sink_types table.
function apply_sink_rules(sink_type)
	if type(logging_config) == "table" then

		for _, level in ipairs(logging_levels) do
			if type(logging_config[level]) == "string" then
				local value = logging_config[level];
				if sink_type == "file" and not value:match("^%*") then
					add_rule({
						to = sink_type;
						filename = value;
						timestamps = true;
						levels = { min = level };
					});
				elseif value == "*"..sink_type then
					add_rule({
						to = sink_type;
						levels = { min = level };
					});
				end
			end
		end

		for _, sink_config in ipairs(logging_config) do
			if (type(sink_config) == "table" and sink_config.to == sink_type) then
				add_rule(sink_config);
			elseif (type(sink_config) == "string" and sink_config:match("^%*(.+)") == sink_type) then
				add_rule({ levels = { min = "debug" }, to = sink_type });
			end
		end
	elseif type(logging_config) == "string" and (not logging_config:match("^%*")) and sink_type == "file" then
		-- User specified simply a filename, and the "file" sink type
		-- was just added
		for _, sink_config in pairs(default_file_logging) do
			sink_config.filename = logging_config;
			add_rule(sink_config);
			sink_config.filename = nil;
		end
	elseif type(logging_config) == "string" and logging_config:match("^%*(.+)") == sink_type then
		-- Log all levels (debug+) to this sink
		add_rule({ levels = { min = "debug" }, to = sink_type });
	end
end



--- Helper function to get a set of levels given a "criteria" table
function get_levels(criteria, set)
	set = set or {};
	if type(criteria) == "string" then
		set[criteria] = true;
		return set;
	end
	local min, max = criteria.min, criteria.max;
	if min or max then
		local in_range;
		for _, level in ipairs(logging_levels) do
			if min == level then
				set[level] = true;
				in_range = true;
			elseif max == level then
				set[level] = true;
				return set;
			elseif in_range then
				set[level] = true;
			end
		end
	end

	for _, level in ipairs(criteria) do
		set[level] = true;
	end
	return set;
end

-- Initialize config, etc. --
function reload_logging()
	local old_sink_types = {};

	for name, sink_maker in pairs(log_sink_types) do
		old_sink_types[name] = sink_maker;
		log_sink_types[name] = nil;
	end

	logger.reset();

	local debug_mode = config.get("*", "debug");

	default_logging = { { to = "console" , levels = { min = (debug_mode and "debug") or "info" } } };
	default_file_logging = {
		{ to = "file", levels = { min = (debug_mode and "debug") or "info" }, timestamps = true }
	};
	default_timestamp = "%b %d %H:%M:%S";

	logging_config = config.get("*", "log") or default_logging;


	for name, sink_maker in pairs(old_sink_types) do
		log_sink_types[name] = sink_maker;
	end

	prosody.events.fire_event("logging-reloaded");
end

reload_logging();
prosody.events.add_handler("config-reloaded", reload_logging);

--- Definition of built-in logging sinks ---

-- Null sink, must enter log_sink_types *first*
function log_sink_types.nowhere()
	return function () return false; end;
end

-- Column width for "source" (used by stdout and console)
local sourcewidth = 20;

function log_sink_types.stdout(sink_config)
	local timestamps = sink_config.timestamps;

	if timestamps == true then
		timestamps = default_timestamp; -- Default format
	end

	return function (name, level, message, ...)
		sourcewidth = math_max(#name+2, sourcewidth);
		local namelen = #name;
		if timestamps then
			io_write(os_date(timestamps), " ");
		end
		if ... then
			io_write(name, rep(" ", sourcewidth-namelen), level, "\t", format(message, ...), "\n");
		else
			io_write(name, rep(" ", sourcewidth-namelen), level, "\t", message, "\n");
		end
	end
end

do
	local do_pretty_printing = true;

	local logstyles = {};
	if do_pretty_printing then
		logstyles["info"] = getstyle("bold");
		logstyles["warn"] = getstyle("bold", "yellow");
		logstyles["error"] = getstyle("bold", "red");
	end
	function log_sink_types.console(sink_config)
		-- Really if we don't want pretty colours then just use plain stdout
		if not do_pretty_printing then
			return log_sink_types.stdout(sink_config);
		end

		local timestamps = sink_config.timestamps;

		if timestamps == true then
			timestamps = default_timestamp; -- Default format
		end

		return function (name, level, message, ...)
			sourcewidth = math_max(#name+2, sourcewidth);
			local namelen = #name;

			if timestamps then
				io_write(os_date(timestamps), " ");
			end
			io_write(name, rep(" ", sourcewidth-namelen));
			setstyle(logstyles[level]);
			io_write(level);
			setstyle();
			if ... then
				io_write("\t", format(message, ...), "\n");
			else
				io_write("\t", message, "\n");
			end
		end
	end
end

local empty_function = function () end;
function log_sink_types.file(sink_config)
	local log = sink_config.filename;
	local logfile = io_open(log, "a+");
	if not logfile then
		return empty_function;
	end
	local write, flush = logfile.write, logfile.flush;

	local timestamps = sink_config.timestamps;

	if timestamps == nil or timestamps == true then
		timestamps = default_timestamp; -- Default format
	end

	return function (name, level, message, ...)
		if timestamps then
			write(logfile, os_date(timestamps), " ");
		end
		if ... then
			write(logfile, name, "\t", level, "\t", format(message, ...), "\n");
		else
			write(logfile, name, "\t" , level, "\t", message, "\n");
		end
		flush(logfile);
	end;
end

function register_sink_type(name, sink_maker)
	local old_sink_maker = log_sink_types[name];
	log_sink_types[name] = sink_maker;
	return old_sink_maker;
end

return _M;
