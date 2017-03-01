-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local format = string.format;
local print = print;
local debug = debug;
local tostring = tostring;

local getstyle, getstring = require "util.termcolours".getstyle, require "util.termcolours".getstring;
local do_pretty_printing = not os.getenv("WINDIR");

local _ENV = nil
local _M = {}

local logstyles = {};

--TODO: This should be done in config, but we don't have proper config yet
if do_pretty_printing then
	logstyles["info"] = getstyle("bold");
	logstyles["warn"] = getstyle("bold", "yellow");
	logstyles["error"] = getstyle("bold", "red");
end

function _M.init(name)
	--name = nil; -- While this line is not commented, will automatically fill in file/line number info
	return 	function (level, message, ...)
				if level == "debug" or level == "info" then return; end
				if not name then
					local inf = debug.getinfo(3, 'Snl');
					level = level .. ","..tostring(inf.short_src):match("[^/]*$")..":"..inf.currentline;
				end
				if ... then
					print(name, getstring(logstyles[level], level), format(message, ...));
				else
					print(name, getstring(logstyles[level], level), message);
				end
			end
end

return _M;
