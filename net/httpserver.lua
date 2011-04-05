-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local server = require "net.server"
local url_parse = require "socket.url".parse;
local httpstream_new = require "util.httpstream".new;

local connlisteners_start = require "net.connlisteners".start;
local connlisteners_get = require "net.connlisteners".get;
local listener;

local t_insert, t_concat = table.insert, table.concat;
local tonumber, tostring, pairs, ipairs, type = tonumber, tostring, pairs, ipairs, type;
local xpcall = xpcall;
local debug_traceback = debug.traceback;

local urlencode = function (s) return s and (s:gsub("%W", function (c) return ("%%%02x"):format(c:byte()); end)); end

local log = require "util.logger".init("httpserver");

local http_servers = {};

module "httpserver"

local default_handler;

local function send_response(request, response)
	-- Write status line
	local resp;
	if response.body or response.headers then
		local body = response.body and tostring(response.body);
		log("debug", "Sending response to %s", request.id);
		resp = { "HTTP/1.0 "..(response.status or "200 OK").."\r\n" };
		local h = response.headers;
		if h then
			for k, v in pairs(h) do
				t_insert(resp, k..": "..v.."\r\n");
			end
		end
		if body and not (h and h["Content-Length"]) then
			t_insert(resp, "Content-Length: "..#body.."\r\n");
		end
		t_insert(resp, "\r\n");
		
		if body and request.method ~= "HEAD" then
			t_insert(resp, body);
		end
		request.write(t_concat(resp));
	else
		-- Response we have is just a string (the body)
		log("debug", "Sending 200 response to %s", request.id or "<none>");
		
		local resp = "HTTP/1.0 200 OK\r\n"
			.. "Connection: close\r\n"
			.. "Content-Type: text/html\r\n"
			.. "Content-Length: "..#response.."\r\n"
			.. "\r\n"
			.. response;
		
		request.write(resp);
	end
	if not request.stayopen then
		request:destroy();
	end
end

local function call_callback(request, err)
	if request.handled then return; end
	request.handled = true;
	local callback = request.callback;
	if not callback and request.path then
		local path = request.url.path;
		local base = path:match("^/([^/?]+)");
		if not base then
			base = path:match("^http://[^/?]+/([^/?]+)");
		end
		
		callback = (request.server and request.server.handlers[base]) or default_handler;
	end
	if callback then
		local _callback = callback;
		function callback(method, body, request)
			local ok, result = xpcall(function() return _callback(method, body, request) end, debug_traceback);
			if ok then return result; end
			log("error", "Error in HTTP server handler: %s", result);
			-- TODO: When we support pipelining, request.destroyed
			-- won't be the right flag - we just want to see if there
			-- has been a response to this request yet.
			if not request.destroyed then
				return {
					status = "500 Internal Server Error";
					headers = { ["Content-Type"] = "text/plain" };
					body = "There was an error processing your request. See the error log for more details.";
				};
			end
		end
		if err then
			log("debug", "Request error: "..err);
			if not callback(nil, err, request) then
				destroy_request(request);
			end
			return;
		end
		
		local response = callback(request.method, request.body and t_concat(request.body), request);
		if response then
			if response == true and not request.destroyed then
				-- Keep connection open, we will reply later
				log("debug", "Request %s left open, on_destroy is %s", request.id, tostring(request.on_destroy));
			elseif response ~= true then
				-- Assume response
				send_response(request, response);
				destroy_request(request);
			end
		else
			log("debug", "Request handler provided no response, destroying request...");
			-- No response, close connection
			destroy_request(request);
		end
	end
end

local function request_reader(request, data, startpos)
	if not request.parser then
		local function success_cb(r)
			for k,v in pairs(r) do request[k] = v; end
			request.url = url_parse(request.path);
			request.url.path = request.url.path and request.url.path:gsub("%%(%x%x)", function(x) return x.char(tonumber(x, 16)) end);
			request.body = { request.body };
			call_callback(request);
		end
		local function error_cb(r)
			call_callback(request, r or "connection-closed");
			destroy_request(request);
		end
		request.parser = httpstream_new(success_cb, error_cb);
	end
	request.parser:feed(data);
end

-- The default handler for requests
default_handler = function (method, body, request)
	log("debug", method.." request for "..tostring(request.path) .. " on port "..request.handler:serverport());
	return { status = "404 Not Found",
			headers = { ["Content-Type"] = "text/html" },
			body = "<html><head><title>Page Not Found</title></head><body>Not here :(</body></html>" };
end


function new_request(handler)
	return { handler = handler, conn = handler,
			write = function (...) return handler:write(...); end, state = "request",
			server = http_servers[handler:serverport()],
			send = send_response,
			destroy = destroy_request,
			id = tostring{}:match("%x+$")
			 };
end

function destroy_request(request)
	log("debug", "Destroying request %s", request.id);
	listener = listener or connlisteners_get("httpserver");
	if not request.destroyed then
		request.destroyed = true;
		if request.on_destroy then
			log("debug", "Request has destroy callback");
			request.on_destroy(request);
		else
			log("debug", "Request has no destroy callback");
		end
		request.handler:close()
		if request.conn then
			listener.ondisconnect(request.conn, "closed");
		end
	end
end

function new(params)
	local http_server = http_servers[params.port];
	if not http_server then
		http_server = { handlers = {} };
		http_servers[params.port] = http_server;
		-- We weren't already listening on this port, so start now
		connlisteners_start("httpserver", params);
	end
	if params.base then
		http_server.handlers[params.base] = params.handler;
	end
end

function set_default_handler(handler)
	default_handler = handler;
end

function new_from_config(ports, handle_request, default_options)
	if type(handle_request) == "string" then -- COMPAT with old plugins
		log("warn", "Old syntax of httpserver.new_from_config being used to register %s", handle_request);
		handle_request, default_options = default_options, { base = handle_request };
	end
	ports = ports or {5280};
	for _, options in ipairs(ports) do
		local port = default_options.port or 5280;
		local base = default_options.base;
		local ssl = default_options.ssl or false;
		local interface = default_options.interface;
		if type(options) == "number" then
			port = options;
		elseif type(options) == "table" then
			port = options.port or port;
			base = options.path or base;
			ssl = options.ssl or ssl;
			interface = options.interface or interface;
		elseif type(options) == "string" then
			base = options;
		end
		
		if ssl then
			ssl.mode = "server";
			ssl.protocol = "sslv23";
			ssl.options = "no_sslv2";
		end
		
		new{ port = port, interface = interface,
			base = base, handler = handle_request,
			ssl = ssl, type = (ssl and "ssl") or "tcp" };
	end
end

_M.request_reader = request_reader;
_M.send_response = send_response;
_M.urlencode = urlencode;

return _M;
