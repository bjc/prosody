-- Prosody IM v0.3
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


module.host = "*" -- Global module

local httpserver = require "net.httpserver";
local st = require "util.stanza";
local pcall = pcall;
local unpack = unpack;
local tostring = tostring;

local translate_request = require "util.xmlrpc".translate_request;
local create_response = require "util.xmlrpc".create_response;
local create_error_response = require "util.xmlrpc".create_error_response;

local entity_map = setmetatable({
	["amp"] = "&";
	["gt"] = ">";
	["lt"] = "<";
	["apos"] = "'";
	["quot"] = "\"";
}, {__index = function(_, s)
		if s:sub(1,1) == "#" then
			if s:sub(2,2) == "x" then
				return string.char(tonumber(s:sub(3), 16));
			else
				return string.char(tonumber(s:sub(2)));
			end
		end
	end
});
local function xml_unescape(str)
	return (str:gsub("&(.-);", entity_map));
end
local function parse_xml(xml)
	local stanza = st.stanza("root");
	local regexp = "<([^>]*)>([^<]*)";
	for elem, text in xml:gmatch(regexp) do
		--print("[<"..elem..">|"..text.."]");
		if elem:sub(1,1) == "!" or elem:sub(1,1) == "?" then -- neglect comments and processing-instructions
		elseif elem:sub(1,1) == "/" then -- end tag
			elem = elem:sub(2);
			stanza:up(); -- TODO check for start-end tag name match
		elseif elem:sub(-1,-1) == "/" then -- empty tag
			elem = elem:sub(1,-2);
			stanza:tag(elem):up();
		else -- start tag
			stanza:tag(elem);
		end
		if #text ~= 0 then -- text
			stanza:text(xml_unescape(text));
		end
	end
	return stanza.tags[1];
end

--[[local function get_method(method)
	return function(...)
		return {method = method; args = {...}};
	end
end]]
local get_method = require "core.objectmanager".get_object;

local function handle_xmlrpc_request(method, args)
	method = get_method(method);
	if not method then return create_error_response(404, "method not found"); end
	args = args or {};
	local success, result = pcall(method, unpack(args));
	if success then
		success, result = pcall(create_response, result or "nil");
		if success then
			return result;
		end
		return create_error_response(500, "Error in creating response: "..result);
	end
	return create_error_response(0, result or "nil");
end

local function handle_xmpp_request(origin, stanza)
	local query = stanza.tags[1];
	if query.name == "query" then
		if #query.tags == 1 then
			local success, method, args = pcall(translate_request, query.tags[1]);
			if success then
				local result = handle_xmlrpc_request(method, args);
				origin.send(st.reply(stanza):tag('query', {xmlns='jabber:iq:rpc'}):add_child(result));
			else
				origin.send(st.error_reply(stanza, "modify", "bad-request", method));
			end
		else
			origin.send(st.error_reply(stanza, "modify", "bad-request", "No content in XML-RPC request"));
		end
	else
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	end
end
module:add_iq_handler({"c2s", "s2sin"}, "jabber:iq:rpc", handle_xmpp_request);
module:add_feature("jabber:iq:rpc");

local default_headers = { ["Content-Type"] = "text/xml" };
local function handle_http_request(method, body, request)
	local stanza = body and parse_xml(body);
	if (not stanza) or request.method ~= "POST" then
		return "<html><body>You really don't look like an XML-RPC client to me... what do you want?</body></html>";
	end
	local success, method, args = pcall(translate_request, stanza);
	if success then
		return { headers = default_headers; body = tostring(handle_xmlrpc_request(method, args)) };
	end
	return "<html><body>Error parsing XML-RPC request: "..tostring(method).."</body></html>";
end
httpserver.new{ port = 9000, base = "xmlrpc", handler = handle_http_request }
