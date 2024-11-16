-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local format = require "prosody.util.format".format;
local setmetatable, rawset, pairs, ipairs, type =
	setmetatable, rawset, pairs, ipairs, type;
local stdout = io.stdout;
local io_open = io.open;
local math_max, rep = math.max, string.rep;
local os_date = os.date;
local getstyle, getstring = require "prosody.util.termcolours".getstyle, require "prosody.util.termcolours".getstring;
local st = require "prosody.util.stanza";

local config = require "prosody.core.configmanager";
local logger = require "prosody.util.logger";

local have_pposix, pposix = pcall(require, "prosody.util.pposix");
have_pposix = have_pposix and pposix._VERSION == "0.4.1";

local _ENV = nil;
-- luacheck: std none

-- The log config used if none specified in the config file (see reload_logging for initialization)
local default_logging;
local default_file_logging;
local default_timestamp = "%b %d %H:%M:%S ";
-- The actual config loggingmanager is using
local logging_config;

local apply_sink_rules;
local log_sink_types = setmetatable({}, { __newindex = function (t, k, v) rawset(t, k, v); apply_sink_rules(k); end; });
local get_levels;
local logging_levels = { "debug", "info", "warn", "error" }

local function id(x) return x end

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
local function reload_logging()
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

	logging_config = config.get("*", "log") or default_logging;

	for name, sink_maker in pairs(old_sink_types) do
		log_sink_types[name] = sink_maker;
	end
end

--- Definition of built-in logging sinks ---

-- Null sink, must enter log_sink_types *first*
local function log_to_nowhere()
	return function () return false; end;
end
log_sink_types.nowhere = log_to_nowhere;

local function log_to_file(sink_config, logfile)
	logfile = logfile or io_open(sink_config.filename, "a+");
	if not logfile then
		return log_to_nowhere(sink_config);
	end
	local write = logfile.write;

	local timestamps = sink_config.timestamps;

	if timestamps == true or timestamps == nil then
		timestamps = default_timestamp; -- Default format
	elseif timestamps then
		timestamps = timestamps .. " ";
	end

	if sink_config.buffer_mode ~= false then
		logfile:setvbuf(sink_config.buffer_mode or "line");
	end

	-- Column width for "source" (used by stdout and console)
	local sourcewidth = sink_config.source_width;
	local filter = sink_config.filter or id;

	if sourcewidth then
		return function (name, level, message, ...)
			sourcewidth = math_max(#name+2, sourcewidth);
			write(logfile, timestamps and os_date(timestamps) or "", name, rep(" ", sourcewidth-#name), level, "\t", filter(format(message, ...)), "\n");
		end
	else
		return function (name, level, message, ...)
			write(logfile, timestamps and os_date(timestamps) or "", name, "\t", level, "\t", filter(format(message, ...)), "\n");
		end
	end
end
log_sink_types.file = log_to_file;

local function log_to_stdout(sink_config)
	if not sink_config.timestamps then
		sink_config.timestamps = false;
	end
	if sink_config.source_width == nil then
		sink_config.source_width = 20;
	end
	return log_to_file(sink_config, stdout);
end
log_sink_types.stdout = log_to_stdout;

local do_pretty_printing = not have_pposix or pposix.isatty(stdout);

local logstyles, pretty;
if do_pretty_printing then
	logstyles = {};
	logstyles["info"] = getstyle("bold");
	logstyles["warn"] = getstyle("bold", "yellow");
	logstyles["error"] = getstyle("bold", "red");

	pretty = st.pretty_print;
end

local function log_to_console(sink_config)
	-- Really if we don't want pretty colours then just use plain stdout
	-- FIXME refactor to allow console logging with colours on stderr
	if not do_pretty_printing then
		return log_to_stdout(sink_config);
	end
	sink_config.filter = pretty;
	local logstdout = log_to_stdout(sink_config);
	return function (name, level, message, ...)
		local logstyle = logstyles[level];
		if logstyle then
			level = getstring(logstyle, level);
		end
		return logstdout(name, level, message, ...);
	end
end
log_sink_types.console = log_to_console;

if have_pposix then
	local syslog_opened;
	local function log_to_syslog(sink_config) -- luacheck: ignore 212/sink_config
		if not syslog_opened then
			local facility = sink_config.syslog_facility or config.get("*", "syslog_facility");
			pposix.syslog_open(sink_config.syslog_name or "prosody", facility);
			syslog_opened = true;
		end
		local syslog = pposix.syslog_log;
		return function (name, level, message, ...)
			syslog(level, name, format(message, ...));
		end;
	end
	log_sink_types.syslog = log_to_syslog;
end

local function register_sink_type(name, sink_maker)
	local old_sink_maker = log_sink_types[name];
	log_sink_types[name] = sink_maker;
	return old_sink_maker;
end

return {
	reload_logging = reload_logging;
	register_sink_type = register_sink_type;
}
