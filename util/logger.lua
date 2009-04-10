-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local format, rep = string.format, string.rep;
local io_write = io.write;
local pcall = pcall;
local debug = debug;
local tostring = tostring;
local math_max = math.max;

local config = require "core.configmanager";
local log_sources = config.get("*", "core", "log_sources");

local getstyle, getstring = require "util.termcolours".getstyle, require "util.termcolours".getstring;
local do_pretty_printing = not os.getenv("WINDIR");
local find = string.find;
local ipairs = ipairs;

module "logger"

local logstyles = {};

--TODO: This should be done in config, but we don't have proper config yet
if do_pretty_printing then
	logstyles["info"] = getstyle("bold");
	logstyles["warn"] = getstyle("bold", "yellow");
	logstyles["error"] = getstyle("bold", "red");
end

local sourcewidth = 20;

local outfunction = nil;

function init(name)
	if log_sources then
		local log_this = false;
		for _, source in ipairs(log_sources) do
			if find(name, source) then 
				log_this = true;
				break;
			end
		end
		
		if not log_this then return function () end end
	end
	
	if name == "modulemanager" or name:match("^c2s") or name == "datamanager" then return function () end; end
	
	--name = nil; -- While this line is not commented, will automatically fill in file/line number info
	local namelen = #name;
	return 	function (level, message, ...)
				if outfunction then return outfunction(name, level, message, ...); end
				
				sourcewidth = math_max(#name+2, sourcewidth);
				if ... then 
					io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", format(message, ...), "\n");
				else
					io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", message, "\n");
				end
			end
end

function setwriter(f)
	local old_func = outfunction;
	if not f then outfunction = nil; return true, old_func; end
	local ok, ret = pcall(f, "logger", "info", "Switched logging output successfully");
	if ok then
		outfunction = f;
		ret = old_func;
	end
	return ok, ret;
end

return _M;
