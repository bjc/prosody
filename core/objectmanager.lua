-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local new_multitable = require "util.multitable".new;
local t_insert = table.insert;
local t_concat = table.concat;
local tostring = tostring;
local unpack = unpack;
local pairs = pairs;
local error = error;
local type = type;
local _G = _G;

local data = new_multitable();

module "objectmanager"

function set(...)
	return data:set(...);
end
function remove(...)
	return data:remove(...);
end
function get(...)
	return data:get(...);
end

local function get_path(path)
	if type(path) == "table" then return path; end
	local s = {};
	for part in tostring(path):gmatch("[%w_]+") do
		t_insert(s, part);
	end
	return s;
end

function get_object(path)
	path = get_path(path)
	return data:get(unpack(path)), path;
end
function set_object(path, object)
	path = get_path(path);
	data:set(unpack(path), object);
end

data:set("ls", function(_dir)
	local obj, dir = get_object(_dir);
	if not obj then error("object not found: " .. t_concat(dir, '/')); end
	local r = {};
	if type(obj) == "table" then
		for key, val in pairs(obj) do
			r[key] = type(val);
		end
	end
	return r;
end);
data:set("get", get_object);
data:set("set", set_object);
data:set("echo", function(...) return {...}; end);
data:set("_G", _G);

return _M;
