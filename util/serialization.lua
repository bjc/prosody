-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local string_rep = string.rep;
local type = type;
local tostring = tostring;
local t_insert = table.insert;
local t_concat = table.concat;
local error = error;
local pairs = pairs;
local next = next;

local loadstring = loadstring;
local pcall = pcall;

local debug_traceback = debug.traceback;
local log = require "util.logger".init("serialization");
local envload = require"util.envload".envload;

module "serialization"

local indent = function(i)
	return string_rep("\t", i);
end
local function basicSerialize (o)
	if type(o) == "number" or type(o) == "boolean" then
		-- no need to check for NaN, as that's not a valid table index
		if o == 1/0 then return "(1/0)";
		elseif o == -1/0 then return "(-1/0)";
		else return tostring(o); end
	else -- assume it is a string -- FIXME make sure it's a string. throw an error otherwise.
		return (("%q"):format(tostring(o)):gsub("\\\n", "\\n"));
	end
end
local function _simplesave(o, ind, t, func)
	if type(o) == "number" then
		if o ~= o then func(t, "(0/0)");
		elseif o == 1/0 then func(t, "(1/0)");
		elseif o == -1/0 then func(t, "(-1/0)");
		else func(t, tostring(o)); end
	elseif type(o) == "string" then
		func(t, (("%q"):format(o):gsub("\\\n", "\\n")));
	elseif type(o) == "table" then
		if next(o) ~= nil then
			func(t, "{\n");
			for k,v in pairs(o) do
				func(t, indent(ind));
				func(t, "[");
				func(t, basicSerialize(k));
				func(t, "] = ");
				if ind == 0 then
					_simplesave(v, 0, t, func);
				else
					_simplesave(v, ind+1, t, func);
				end
				func(t, ";\n");
			end
			func(t, indent(ind-1));
			func(t, "}");
		else
			func(t, "{}");
		end
	elseif type(o) == "boolean" then
		func(t, (o and "true" or "false"));
	else
		log("error", "cannot serialize a %s: %s", type(o), debug_traceback())
		func(t, "nil");
	end
end

function append(t, o)
	_simplesave(o, 1, t, t.write or t_insert);
	return t;
end

function serialize(o)
	return t_concat(append({}, o));
end

function deserialize(str)
	if type(str) ~= "string" then return nil; end
	str = "return "..str;
	local f, err = envload(str, "@data", {});
	if not f then return nil, err; end
	local success, ret = pcall(f);
	if not success then return nil, ret; end
	return ret;
end

return _M;
