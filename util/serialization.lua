-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
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

module "serialization"

local indent = function(i)
	return string_rep("\t", i);
end
local function basicSerialize (o)
	if type(o) == "number" or type(o) == "boolean" then
		return tostring(o);
	else -- assume it is a string -- FIXME make sure it's a string. throw an error otherwise.
		return (("%q"):format(tostring(o)):gsub("\\\n", "\\n"));
	end
end
local function _simplesave(o, ind, t, func)
	if type(o) == "number" then
		func(t, tostring(o));
	elseif type(o) == "string" then
		func(t, (("%q"):format(o):gsub("\\\n", "\\n")));
	elseif type(o) == "table" then
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
			func(t, ",\n");
		end
		func(t, indent(ind-1));
		func(t, "}");
	elseif type(o) == "boolean" then
		func(t, (o and "true" or "false"));
	else
		error("cannot serialize a " .. type(o))
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
	error("Not implemented");
end

return _M;
