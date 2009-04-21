
local format, rep = string.format, string.rep;
local io_write = io.write;
local pcall = pcall;
local debug = debug;
local tostring = tostring;
local math_max = math.max;

local logger = require "util.logger";

-- Global log function, because some people are too 
-- lazy to get their own...
_G.log = logger.init("general");

local log_sink_types = {};
local get_levels;

--- Main function to read config, create the appropriate sinks and tell logger module
function setup_logging(log)
	log = log or config.get("*", "core", "log") or default_logging;
	-- Set default logger
	if type(log) == "string" then
		if not log:match("^%*") then
		end
	elseif type(log) == "table" then
		-- Advanced configuration chosen
		for i, sink_config in ipairs(log) do
			local sink_maker = log_sink_types[sink_config.to];
			if sink_maker then
				if sink_config.levels and not sink_config.source then
					-- Create sink
					local sink = sink_maker(sink_config);
					
					-- Set sink for all chosen levels
					for level in pairs(get_levels(sink_config.levels)) do
						logger.add_level_sink(level, sink);
					end
				elseif sink_config.source and not sink_config.levels then
					logger.add_name_sink(sink_config.source, sink_maker(sink_config));
				elseif sink_config.source and sink_config.levels then
					local levels = get_levels(sink_config.levels);
					local sink = sink_maker(sink_config);
					logger.add_name_sink(sink_config.source,
						function (name, level, ...)
							if levels[level] then
								return sink(name, level, ...);
							end
						end);
				else
					-- All sources	
				end
			else
				-- No such sink type
			end
		end
	end
end

--- Definition of built-in logging sinks ---
local math_max, rep = math.max, string.rep;

-- Column width for "source" (used by stdout and console)

function log_sink_types.nowhere()
	return function () return false; end;
end

local sourcewidth = 20;

function log_sink_types.stdout()
	return function (name, level, message, ...)
		sourcewidth = math_max(#name+2, sourcewidth);
		local namelen = #name;
		if ... then 
			io_write(name, rep(" ", sourcewidth-namelen), level, "\t", format(message, ...), "\n");
		else
			io_write(name, rep(" ", sourcewidth-namelen), level, "\t", message, "\n");
		end
	end	
end

do
	local getstyle, getstring = require "util.termcolours".getstyle, require "util.termcolours".getstring;
	local do_pretty_printing = not os.getenv("WINDIR");
	
	local logstyles = {};
	if do_pretty_printing then
		logstyles["info"] = getstyle("bold");
		logstyles["warn"] = getstyle("bold", "yellow");
		logstyles["error"] = getstyle("bold", "red");
	end
	function log_sink_types.console(config)
		-- Really if we don't want pretty colours then just use plain stdout
		if not do_pretty_printing then
			return log_sink_types.stdout(config);
		end
		
		return function (name, level, message, ...)
			sourcewidth = math_max(#name+2, sourcewidth);
			local namelen = #name;
			if ... then 
				io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", format(message, ...), "\n");
			else
				io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", message, "\n");
			end
		end
	end
end

function log_sink_types.file(config)
	local log = config.filename;
	local logfile = io.open(log, "a+");
	if not logfile then
		return function () end
	end

	local write, format, flush = logfile.write, string.format, logfile.flush;
	return function (name, level, message, ...)
		if ... then 
			write(logfile, name, "\t", level, "\t", format(message, ...), "\n");
		else
			write(logfile, name, "\t" , level, "\t", message, "\n");
		end
		flush(logfile);
	end;
end

function log_sink_types.syslog()
end

--- Helper function to get a set of levels given a "criteria" table
local logging_levels = { "debug", "info", "warn", "error", "critical" }

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

--- Set up logging
setup_logging();

