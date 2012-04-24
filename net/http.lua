-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local socket = require "socket"
local mime = require "mime"
local url = require "socket.url"
local httpstream_new = require "util.httpstream".new;

local server = require "net.server"

local t_insert, t_concat = table.insert, table.concat;
local pairs, ipairs = pairs, ipairs;
local tonumber, tostring, xpcall, select, debug_traceback, char, format =
      tonumber, tostring, xpcall, select, debug.traceback, string.char, string.format;

local log = require "util.logger".init("http");

module "http"

local requests = {}; -- Open requests

local listener = { default_port = 80, default_mode = "*a" };

function listener.onconnect(conn)
	local req = requests[conn];
	-- Send the request
	local request_line = { req.method or "GET", " ", req.path, " HTTP/1.1\r\n" };
	if req.query then
		t_insert(request_line, 4, "?"..req.query);
	end
	
	conn:write(t_concat(request_line));
	local t = { [2] = ": ", [4] = "\r\n" };
	for k, v in pairs(req.headers) do
		t[1], t[3] = k, v;
		conn:write(t_concat(t));
	end
	conn:write("\r\n");
	
	if req.body then
		conn:write(req.body);
	end
end

function listener.onincoming(conn, data)
	local request = requests[conn];

	if not request then
		log("warn", "Received response from connection %s with no request attached!", tostring(conn));
		return;
	end

	if data and request.reader then
		request:reader(data);
	end
end

function listener.ondisconnect(conn, err)
	local request = requests[conn];
	if request and request.conn then
		request:reader(nil);
	end
	requests[conn] = nil;
end

function urlencode(s) return s and (s:gsub("%W", function (c) return format("%%%02x", c:byte()); end)); end
function urldecode(s) return s and (s:gsub("%%(%x%x)", function (c) return char(tonumber(c,16)); end)); end

local function _formencodepart(s)
	return s and (s:gsub("%W", function (c)
		if c ~= " " then
			return format("%%%02x", c:byte());
		else
			return "+";
		end
	end));
end

function formencode(form)
	local result = {};
	if form[1] then -- Array of ordered { name, value }
		for _, field in ipairs(form) do
			t_insert(result, _formencodepart(field.name).."=".._formencodepart(field.value));
		end
	else -- Unordered map of name -> value
		for name, value in pairs(form) do
			t_insert(result, _formencodepart(name).."=".._formencodepart(value));
		end
	end
	return t_concat(result, "&");
end

function formdecode(s)
	if not s:match("=") then return urldecode(s); end
	local r = {};
	for k, v in s:gmatch("([^=&]*)=([^&]*)") do
		k, v = k:gsub("%+", "%%20"), v:gsub("%+", "%%20");
		k, v = urldecode(k), urldecode(v);
		t_insert(r, { name = k, value = v });
		r[k] = v;
	end
	return r;
end

local function request_reader(request, data, startpos)
	if not request.parser then
		if not data then return; end
		local function success_cb(r)
			if request.callback then
				for k,v in pairs(r) do request[k] = v; end
				request.callback(r.body, r.code, request, r);
				request.callback = nil;
			end
			destroy_request(request);
		end
		local function error_cb(r)
			if request.callback then
				request.callback(r or "connection-closed", 0, request);
				request.callback = nil;
			end
			destroy_request(request);
		end
		local function options_cb()
			return request;
		end
		request.parser = httpstream_new(success_cb, error_cb, "client", options_cb);
	end
	request.parser:feed(data);
end

local function handleerr(err) log("error", "Traceback[http]: %s: %s", tostring(err), debug_traceback()); end
function request(u, ex, callback)
	local req = url.parse(u);
	
	if not (req and req.host) then
		callback(nil, 0, req);
		return nil, "invalid-url";
	end
	
	if not req.path then
		req.path = "/";
	end
	
	local method, headers, body;
	
	headers = {
		["Host"] = req.host;
		["User-Agent"] = "Prosody XMPP Server";
	};
	
	if req.userinfo then
		headers["Authorization"] = "Basic "..mime.b64(req.userinfo);
	end

	if ex then
		req.onlystatus = ex.onlystatus;
		body = ex.body;
		if body then
			method = "POST";
			headers["Content-Length"] = tostring(#body);
			headers["Content-Type"] = "application/x-www-form-urlencoded";
		end
		if ex.method then method = ex.method; end
		if ex.headers then
			for k, v in pairs(ex.headers) do
				headers[k] = v;
			end
		end
	end
	
	-- Attach to request object
	req.method, req.headers, req.body = method, headers, body;
	
	local using_https = req.scheme == "https";
	local port = tonumber(req.port) or (using_https and 443 or 80);
	
	-- Connect the socket, and wrap it with net.server
	local conn = socket.tcp();
	conn:settimeout(10);
	local ok, err = conn:connect(req.host, port);
	if not ok and err ~= "timeout" then
		callback(nil, 0, req);
		return nil, err;
	end
	
	req.handler, req.conn = server.wrapclient(conn, req.host, port, listener, "*a", using_https and { mode = "client", protocol = "sslv23" });
	req.write = function (...) return req.handler:write(...); end
	
	req.callback = function (content, code, request, response) log("debug", "Calling callback, status %s", code or "---"); return select(2, xpcall(function () return callback(content, code, request, response) end, handleerr)); end
	req.reader = request_reader;
	req.state = "status";

	requests[req.handler] = req;
	return req;
end

function destroy_request(request)
	if request.conn then
		request.conn = nil;
		request.handler:close()
		listener.ondisconnect(request.handler, "closed");
	end
end

_M.urlencode = urlencode;

return _M;
