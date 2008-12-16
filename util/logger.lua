-- Prosody IM v0.2
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--

local format, rep = string.format, string.rep;
local io_write = io.write;
local pcall = pcall;
local debug = debug;
local tostring = tostring;
local math_max = math.max;

local getstyle, getstring = require "util.termcolours".getstyle, require "util.termcolours".getstring;
local do_pretty_printing = not os.getenv("WINDIR");

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
	--name = nil; -- While this line is not commented, will automatically fill in file/line number info
	sourcewidth = math_max(#name+2, sourcewidth);
	local namelen = #name;
	return 	function (level, message, ...)
				if not name then
					local inf = debug.getinfo(3, 'Snl');
					level = level .. ","..tostring(inf.short_src):match("[^/]*$")..":"..inf.currentline;
				end
				
				if outfunction then return outfunction(name, level, message, ...); end
				
				if ... then 
					io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", format(message, ...), "\n");
				else
					io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", message, "\n");
				end
			end
end

function setwriter(f)
	if not f then outfunction = nil; return true, nil; end
	local ok, ret = pcall(f, "logger", "info", "Switched logging output successfully");
	if ok then
		outfunction = f;
	end
	return ok, ret;
end

return _M;
