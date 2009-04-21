
local format, rep = string.format, string.rep;
local io_write = io.write;
local pcall = pcall;
local debug = debug;
local tostring = tostring;
local math_max = math.max;

local logger = require "util.logger";

-- Global log function, because some people are too 
-- lazy to get their own
_G.log = logger.init("general");

-- Disable log output, needs to read from config
-- logger.setwriter(function () end);

local getstyle, getstring = require "util.termcolours".getstyle, require "util.termcolours".getstring;
local do_pretty_printing = not os.getenv("WINDIR");

local logstyles = {};

--TODO: This should be done in config, but we don't have proper config yet
if do_pretty_printing then
	logstyles["info"] = getstyle("bold");
	logstyles["warn"] = getstyle("bold", "yellow");
	logstyles["error"] = getstyle("bold", "red");
end

local sourcewidth = 20;
local math_max, rep = math.max, string.rep;
local function make_default_log_sink(level)
	return function (name, _level, message, ...)
		sourcewidth = math_max(#name+2, sourcewidth);
		local namelen = #name;
		if ... then 
			io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", format(message, ...), "\n");
		else
			io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", message, "\n");
		end
	end
end

-- Set default sinks
logger.add_level_sink("debug", make_default_log_sink("debug"));
logger.add_level_sink("info", make_default_log_sink("info"));
logger.add_level_sink("warn", make_default_log_sink("warn"));
logger.add_level_sink("error", make_default_log_sink("error"));

