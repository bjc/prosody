-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local pairs = pairs;
local type = type;
local error = error;
local t_concat = table.concat;
local t_insert = table.insert;
local tostring = tostring;
local tonumber = tonumber;
local select = select;
local st = require "util.stanza";

module "xmlrpc"

local _lua_to_xmlrpc;
local map = {
	table=function(stanza, object)
		stanza:tag("struct");
		for name, value in pairs(object) do
			stanza:tag("member");
				stanza:tag("name"):text(tostring(name)):up();
				stanza:tag("value");
					_lua_to_xmlrpc(stanza, value);
				stanza:up();
			stanza:up();
		end
		stanza:up();
	end;
	boolean=function(stanza, object)
		stanza:tag("boolean"):text(object and "1" or "0"):up();
	end;
	string=function(stanza, object)
		stanza:tag("string"):text(object):up();
	end;
	number=function(stanza, object)
		stanza:tag("int"):text(tostring(object)):up();
	end;
	["nil"]=function(stanza, object) -- nil extension
		stanza:tag("nil"):up();
	end;
};
_lua_to_xmlrpc = function(stanza, object)
	local h = map[type(object)];
	if h then
		h(stanza, object);
	else
		error("Type not supported by XML-RPC: " .. type(object));
	end
end
function create_response(object)
	local stanza = st.stanza("methodResponse"):tag("params"):tag("param"):tag("value");
	_lua_to_xmlrpc(stanza, object);
	stanza:up():up():up();
	return stanza;
end
function create_error_response(faultCode, faultString)
	local stanza = st.stanza("methodResponse"):tag("fault"):tag("value");
	_lua_to_xmlrpc(stanza, {faultCode=faultCode, faultString=faultString});
	stanza:up():up();
	return stanza;
end

function create_request(method_name, ...)
	local stanza = st.stanza("methodCall")
		:tag("methodName"):text(method_name):up()
		:tag("params");
	for i=1,select('#', ...) do
		stanza:tag("param"):tag("value");
		_lua_to_xmlrpc(stanza, select(i, ...));
		stanza:up():up();
	end
	stanza:up():up():up();
	return stanza;
end

local _xmlrpc_to_lua;
local int_parse = function(stanza)
	if #stanza.tags ~= 0 or #stanza == 0 then error("<"..stanza.name.."> must have a single text child"); end
	local n = tonumber(t_concat(stanza));
	if n then return n; end
	error("Failed to parse content of <"..stanza.name..">");
end
local rmap = {
	methodCall=function(stanza)
		if #stanza.tags ~= 2 then error("<methodCall> must have exactly two subtags"); end -- FIXME <params> is optional
		if stanza.tags[1].name ~= "methodName" then error("First <methodCall> child tag must be <methodName>") end
		if stanza.tags[2].name ~= "params" then error("Second <methodCall> child tag must be <params>") end
		return _xmlrpc_to_lua(stanza.tags[1]), _xmlrpc_to_lua(stanza.tags[2]);
	end;
	methodName=function(stanza)
		if #stanza.tags ~= 0 then error("<methodName> must not have any subtags"); end
		if #stanza == 0 then error("<methodName> must have text content"); end
		return t_concat(stanza);
	end;
	params=function(stanza)
		local t = {};
		for _, child in pairs(stanza.tags) do
			if child.name ~= "param" then error("<params> can only have <param> children"); end;
			t_insert(t, _xmlrpc_to_lua(child));
		end
		return t;
	end;
	param=function(stanza)
		if not(#stanza.tags == 1 and stanza.tags[1].name == "value") then error("<param> must have exactly one <value> child"); end
		return _xmlrpc_to_lua(stanza.tags[1]);
	end;
	value=function(stanza)
		if #stanza.tags == 0 then return t_concat(stanza); end
		if #stanza.tags ~= 1 then error("<value> must have a single child"); end
		return _xmlrpc_to_lua(stanza.tags[1]);
	end;
	int=int_parse;
	i4=int_parse;
	double=int_parse;
	boolean=function(stanza)
		if #stanza.tags ~= 0 or #stanza == 0 then error("<boolean> must have a single text child"); end
		local b = t_concat(stanza);
		if b ~= "1" and b ~= "0" then error("Failed to parse content of <boolean>"); end
		return b == "1" and true or false;
	end;
	string=function(stanza)
		if #stanza.tags ~= 0 then error("<string> must have a single text child"); end
		return t_concat(stanza);
	end;
	array=function(stanza)
		if #stanza.tags ~= 1 then error("<array> must have a single <data> child"); end
		return _xmlrpc_to_lua(stanza.tags[1]);
	end;
	data=function(stanza)
		local t = {};
		for _,child in pairs(stanza.tags) do
			if child.name ~= "value" then error("<data> can only have <value> children"); end
			t_insert(t, _xmlrpc_to_lua(child));
		end
		return t;
	end;
	struct=function(stanza)
		local t = {};
		for _,child in pairs(stanza.tags) do
			if child.name ~= "member" then error("<struct> can only have <member> children"); end
			local name, value = _xmlrpc_to_lua(child);
			t[name] = value;
		end
		return t;
	end;
	member=function(stanza)
		if #stanza.tags ~= 2 then error("<member> must have exactly two subtags"); end -- FIXME <params> is optional
		if stanza.tags[1].name ~= "name" then error("First <member> child tag must be <name>") end
		if stanza.tags[2].name ~= "value" then error("Second <member> child tag must be <value>") end
		return _xmlrpc_to_lua(stanza.tags[1]), _xmlrpc_to_lua(stanza.tags[2]);
	end;
	name=function(stanza)
		if #stanza.tags ~= 0 then error("<name> must have a single text child"); end
		local n = t_concat(stanza)
		if tostring(tonumber(n)) == n then n = tonumber(n); end
		return n;
	end;
	["nil"]=function(stanza) -- nil extension
		return nil;
	end;
}
_xmlrpc_to_lua = function(stanza)
	local h = rmap[stanza.name];
	if h then
		return h(stanza);
	else
		error("Unknown element: "..stanza.name);
	end
end
function translate_request(stanza)
	if stanza.name ~= "methodCall" then error("XML-RPC requests must have <methodCall> as root element"); end
	return _xmlrpc_to_lua(stanza);
end

return _M;
