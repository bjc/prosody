-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local b64 = require "util.encodings".base64.encode;
local url = require "socket.url"
local httpstream_new = require "net.http.parser".new;
local util_http = require "util.http";

local ssl_available = pcall(require, "ssl");

local server = require "net.server"

local t_insert, t_concat = table.insert, table.concat;
local pairs = pairs;
local tonumber, tostring, xpcall, select, traceback =
      tonumber, tostring, xpcall, select, debug.traceback;
local assert, error = assert, error

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
		request:reader(nil, err);
	end
	requests[conn] = nil;
end

local function request_reader(request, data, err)
	if not request.parser then
		local function error_cb(reason)
			if request.callback then
				request.callback(reason or "connection-closed", 0, request);
				request.callback = nil;
			end
			destroy_request(request);
		end

		if not data then
			error_cb(err);
			return;
		end

		local function success_cb(r)
			if request.callback then
				request.callback(r.body, r.code, r, request);
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

local function handleerr(err) log("error", "Traceback[http]: %s", traceback(tostring(err), 2)); end
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

	local host, port = req.host, req.port;
	local host_header = host;
	if (port == "80" and req.scheme == "http")
	or (port == "443" and req.scheme == "https") then
		port = nil;
	elseif port then
		host_header = host_header..":"..port;
	end

	headers = {
		["Host"] = host_header;
		["User-Agent"] = "Prosody XMPP Server";
	};

	if req.userinfo then
		headers["Authorization"] = "Basic "..b64(req.userinfo);
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
	if using_https and not ssl_available then
		error("SSL not available, unable to contact https URL");
	end
	local port_number = port and tonumber(port) or (using_https and 443 or 80);

	local sslctx = false;
	if using_https then
		sslctx = ex and ex.sslctx or { mode = "client", protocol = "sslv23", options = { "no_sslv2" } };
	end

	local handler, conn = server.addclient(host, port_number, listener, "*a", sslctx)
	if not handler then
		callback(nil, 0, req);
		return nil, conn;
	end
	req.handler, req.conn = handler, conn
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
	end
end

local urlencode, urldecode = util_http.urlencode, util_http.urldecode;
local formencode, formdecode = util_http.formencode, util_http.formdecode;

_M.urlencode, _M.urldecode = urlencode, urldecode;
_M.formencode, _M.formdecode = formencode, formdecode;

return _M;
