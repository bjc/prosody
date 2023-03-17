-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local b64 = require "prosody.util.encodings".base64.encode;
local url = require "socket.url"
local httpstream_new = require "prosody.net.http.parser".new;
local util_http = require "prosody.util.http";
local events = require "prosody.util.events";
local verify_identity = require"prosody.util.x509".verify_identity;
local promise = require "prosody.util.promise";
local http_errors = require "prosody.net.http.errors";

local basic_resolver = require "prosody.net.resolvers.basic";
local connect = require "prosody.net.connect".connect;

local ssl_available = pcall(require, "ssl");

local t_insert, t_concat = table.insert, table.concat;
local pairs = pairs;
local tonumber, tostring, traceback =
      tonumber, tostring, debug.traceback;
local os_time = os.time;
local xpcall = require "prosody.util.xpcall".xpcall;
local error = error

local log = require "prosody.util.logger".init("http");

local _ENV = nil;
-- luacheck: std none

local requests = {}; -- Open requests

local function make_id(req) return (tostring(req):match("%x+$")); end

local listener = { default_port = 80, default_mode = "*a" };

-- Request-related helper functions
local function handleerr(err) log("error", "Traceback[http]: %s", traceback(tostring(err), 2)); return err; end
local function log_if_failed(req, ret, ...)
	if not ret then
		log("error", "Request '%s': error in callback: %s", req.id, (...));
		if not req.suppress_errors then
			error(...);
		end
	end
	return ...;
end

local function destroy_request(request)
	local conn = request.conn;
	if conn then
		request.conn = nil;
		conn:close()
	end
end

local function cancel_request(request, reason)
	if request.callback then
		request.callback(reason or "cancelled", 0, request);
		request.callback = nil;
	end
	if request.conn then
		destroy_request(request);
	end
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

		local finalize_sink;
		local function success_cb(r)
			if r.partial then
				-- Request should be streamed
				log("debug", "Request '%s': partial response (%s%s)",
					request.id,
					r.chunked and "chunked, " or "",
					r.body_length and ("%d bytes"):format(r.body_length) or "unknown length"
				);
				if request.streaming_handler then
					log("debug", "Request '%s': Streaming via handler", request.id);
					r.body_sink, finalize_sink = request.streaming_handler(r);
				end
				return;
			elseif finalize_sink then
				log("debug", "Request '%s': Finalizing response stream");
				finalize_sink(r);
			end
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

-- Connection listener callbacks
function listener.onconnect(conn)
	local req = requests[conn];

	-- Initialize request object
	req.write = function (...) return req.conn:write(...); end
	local callback = req.callback;
	req.callback = function (content, code, response, request)
		do
			local event = { http = req.http, url = req.url, request = req, response = response, content = content, code = code, callback = req.callback };
			req.http.events.fire_event("response", event);
			content, code, response = event.content, event.code, event.response;
		end

		log("debug", "Request '%s': Calling callback, status %s", req.id, code or "---");
		return log_if_failed(req.id, xpcall(callback, handleerr, content, code, response, request));
	end
	req.reader = request_reader;
	req.state = "status";
	req.cancel = cancel_request;

	requests[req.conn] = req;

	-- Validate certificate
	if not req.insecure and conn:ssl() then
		local sock = conn:socket();
		local chain_valid = sock.getpeerverification and sock:getpeerverification();
		if not chain_valid then
			req.callback("certificate-chain-invalid", 0, req);
			req.callback = nil;
			conn:close();
			return;
		end
		local cert = sock.getpeercertificate and sock:getpeercertificate();
		if not cert or not verify_identity(req.host, false, cert) then
			req.callback("certificate-verify-failed", 0, req);
			req.callback = nil;
			conn:close();
			return;
		end
	end

	-- Send the request
	local request_line = { req.method or "GET", " ", req.path, " HTTP/1.1\r\n" };
	if req.query then
		t_insert(request_line, 4, "?"..req.query);
	end

	for k, v in pairs(req.headers) do
		t_insert(request_line, k .. ": " .. v .. "\r\n");
	end
	t_insert(request_line, "\r\n")
	conn:write(t_concat(request_line));

	if req.body then
		conn:write(req.body);
	end
end

function listener.onincoming(conn, data)
	local request = requests[conn];

	if not request then
		log("warn", "Received response from connection %s with no request attached!", conn);
		return;
	end

	if data and request.reader then
		request:reader(data);
	end
end

function listener.ondisconnect(conn, err)
	local request = requests[conn];
	if request and request.conn then
		request:reader(nil, err or "closed");
	end
	requests[conn] = nil;
end

function listener.onattach(conn, req)
	requests[conn] = req;
	req.conn = conn;
end

function listener.ondetach(conn)
	requests[conn] = nil;
end

function listener.onfail(req, reason)
	req.http.events.fire_event("request-connection-error", { http = req.http, request = req, url = req.url, err = reason });
	req.callback(reason or "connection failed", 0, req);
end

local function request(self, u, ex, callback)
	local req = url.parse(u);

	if not (req and req.host) then
		callback("invalid-url", 0, req);
		return nil, "invalid-url";
	end

	req.url = u;
	req.http = self;
	req.time = os_time();

	if not req.path then
		req.path = "/";
	end

	req.id = ex and ex.id or make_id(req);

	do
		local event = { http = self, url = u, request = req, options = ex, callback = callback };
		local ret = self.events.fire_event("pre-request", event);
		if ret then
			return ret;
		end
		req, u, ex, req.callback = event.request, event.url, event.options, event.callback;
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
		req.insecure = ex.insecure;
		req.suppress_errors = ex.suppress_errors;
		req.streaming_handler = ex.streaming_handler;
	end

	log("debug", "Making %s %s request '%s' to %s", req.scheme:upper(), method or "GET", req.id, (ex and ex.suppress_url and host_header) or u);

	-- Attach to request object
	req.method, req.headers, req.body = method, headers, body;

	local using_https = req.scheme == "https";
	if using_https and not ssl_available then
		error("SSL not available, unable to contact https URL");
	end
	local port_number = port and tonumber(port) or (using_https and 443 or 80);

	local use_dane = self.options and self.options.use_dane;
	local sslctx = false;
	if using_https then
		sslctx = ex and ex.sslctx or self.options and self.options.sslctx;
		if ex and ex.use_dane ~= nil then
			use_dane = ex.use_dane;
		end
	end

	local http_service = basic_resolver.new(host, port_number, "tcp", { servername = req.host; use_dane = use_dane });
	connect(http_service, listener, { sslctx = sslctx }, req);

	self.events.fire_event("request", { http = self, request = req, url = u });
	return req;
end

local function new(options)
	local http = {
		options = options;
		request = function (self, u, ex, callback)
			if callback ~= nil then
				return request(self, u, ex, callback);
			else
				return promise.new(function (resolve, reject)
					request(self, u, ex, function (body, code, a, b)
						if code == 0 then
							reject(http_errors.new(body, { request = a }));
						else
							a.request = b;
							resolve(a);
						end
					end);
				end);
			end
		end;
		new = options and function (new_options)
			local final_options = {};
			for k, v in pairs(options) do final_options[k] = v; end
			if new_options then
				for k, v in pairs(new_options) do final_options[k] = v; end
			end
			return new(final_options);
		end or new;
		events = events.new();
	};
	return http;
end

local default_http = new({
	sslctx = { mode = "client", protocol = "sslv23", options = { "no_sslv2", "no_sslv3" }, alpn = "http/1.1", verify = "peer" };
	suppress_errors = true;
});

return {
	request = function (u, ex, callback)
		return default_http:request(u, ex, callback);
	end;
	default = default_http;
	new = new;
	events = default_http.events;
	-- COMPAT
	urlencode = util_http.urlencode;
	urldecode = util_http.urldecode;
	formencode = util_http.formencode;
	formdecode = util_http.formdecode;
	destroy_request = destroy_request;
	features = {
		sni = true;
	};
};
