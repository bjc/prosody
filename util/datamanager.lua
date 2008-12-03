-- Prosody IM v0.1
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


local format = string.format;
local setmetatable, type = setmetatable, type;
local pairs, ipairs = pairs, ipairs;
local char = string.char;
local loadfile, setfenv, pcall = loadfile, setfenv, pcall;
local log = require "util.logger".init("datamanager");
local io_open = io.open;
local os_remove = os.remove;
local tostring, tonumber = tostring, tonumber;
local error = error;
local next = next;
local t_insert = table.insert;

local indent = function(f, i)
	for n = 1, i do
		f:write("\t");
	end
end

local data_path = "data";

module "datamanager"


---- utils -----
local encode, decode;

do 
	local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = char(tonumber("0x"..k)); return t[k]; end });

	decode = function (s)
		return s and (s:gsub("+", " "):gsub("%%([a-fA-F0-9][a-fA-F0-9])", urlcodes));
	end

	encode = function (s)
		return s and (s:gsub("%W", function (c) return format("%%%x", c:byte()); end));
	end
end

local function basicSerialize (o)
	if type(o) == "number" or type(o) == "boolean" then
		return tostring(o);
	else -- assume it is a string -- FIXME make sure it's a string. throw an error otherwise.
		return (format("%q", tostring(o)):gsub("\\\n", "\\n"));
	end
end


local function simplesave (f, o, ind)
	if type(o) == "number" then
		f:write(o)
	elseif type(o) == "string" then
		f:write((format("%q", o):gsub("\\\n", "\\n")))
	elseif type(o) == "table" then
		f:write("{\n")
		for k,v in pairs(o) do
			indent(f, ind);
			f:write("[", basicSerialize(k), "] = ")
			simplesave(f, v, ind+1)
			f:write(",\n")
		end
		indent(f, ind-1);
		f:write("}")
	elseif type(o) == "boolean" then
		f:write(o and "true" or "false");
	else
		error("cannot serialize a " .. type(o))
	end
end

------- API -------------

function set_data_path(path)
	data_path = path;
end

function getpath(username, host, datastore, ext)
	ext = ext or "dat";
	if username then
		return format("%s/%s/%s/%s.%s", data_path, encode(host), datastore, encode(username), ext);
	elseif host then
		return format("%s/%s/%s.%s", data_path, encode(host), datastore, ext);
	else
		return format("%s/%s.%s", data_path, datastore, ext);
	end
end

function load(username, host, datastore)
	local data, ret = loadfile(getpath(username, host, datastore));
	if not data then
		log("warn", "Failed to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	setfenv(data, {});
	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	return ret;
end

function store(username, host, datastore, data)
	if not data then
		data = {};
	end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore), "w+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return;
	end
	f:write("return ");
	simplesave(f, data, 1);
	f:close();
	if not next(data) then -- try to delete empty datastore
		os_remove(getpath(username, host, datastore));
	end
	-- we write data even when we are deleting because lua doesn't have a
	-- platform independent way of checking for non-exisitng files
	return true;
end

function list_append(username, host, datastore, data)
	if not data then return; end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore, "list"), "a+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return;
	end
	f:write("item(");
	simplesave(f, data, 1);
	f:write(");\n");
	f:close();
	return true;
end

function list_store(username, host, datastore, data)
	if not data then
		data = {};
	end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore, "list"), "w+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return;
	end
	for _, d in ipairs(data) do
		f:write("item(");
		simplesave(f, d, 1);
		f:write(");\n");
	end
	f:close();
	if not next(data) then -- try to delete empty datastore
		os_remove(getpath(username, host, datastore, "list"));
	end
	-- we write data even when we are deleting because lua doesn't have a
	-- platform independent way of checking for non-exisitng files
	return true;
end

function list_load(username, host, datastore)
	local data, ret = loadfile(getpath(username, host, datastore, "list"));
	if not data then
		log("warn", "Failed to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	local items = {};
	setfenv(data, {item = function(i) t_insert(items, i); end});
	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	return items;
end

return _M;
