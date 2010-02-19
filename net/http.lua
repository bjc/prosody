-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local socket = require "socket"
local mime = require "mime"
local url = require "socket.url"

local server = require "net.server"

local connlisteners_get = require "net.connlisteners".get;
local listener = connlisteners_get("httpclient") or error("No httpclient listener!");

local t_insert, t_concat = table.insert, table.concat;
local tonumber, tostring, pairs, xpcall, select, debug_traceback, char, format = 
        tonumber, tostring, pairs, xpcall, select, debug.traceback, string.char, string.format;

local log = require "util.logger".init("http");
local print = function () end

module "http"

function urlencode(s) return s and (s:gsub("%W", function (c) return format("%%%02x", c:byte()); end)); end
function urldecode(s) return s and (s:gsub("%%(%x%x)", function (c) return char(tonumber(c,16)); end)); end

local function expectbody(reqt, code)
    if reqt.method == "HEAD" then return nil end
    if code == 204 or code == 304 or code == 301 then return nil end
    if code >= 100 and code < 200 then return nil end
    return 1
end

local function request_reader(request, data, startpos)
	if not data then
		if request.body then
			log("debug", "Connection closed, but we have data, calling callback...");
			request.callback(t_concat(request.body), request.code, request);
		elseif request.state ~= "completed" then
			-- Error.. connection was closed prematurely
			request.callback("connection-closed", 0, request);
			return;
		end
		destroy_request(request);
		request.body = nil;
		request.state = "completed";
		return;
	end
	if request.state == "body" and request.state ~= "completed" then
		print("Reading body...")
		if not request.body then request.body = {}; request.havebodylength, request.bodylength = 0, tonumber(request.responseheaders["content-length"]); end
		if startpos then
			data = data:sub(startpos, -1)
		end
		t_insert(request.body, data);
		if request.bodylength then
			request.havebodylength = request.havebodylength + #data;
			if request.havebodylength >= request.bodylength then
				-- We have the body
				log("debug", "Have full body, calling callback");
				if request.callback then
					request.callback(t_concat(request.body), request.code, request);
				end
				request.body = nil;
				request.state = "completed";
			else
				print("", "Have "..request.havebodylength.." bytes out of "..request.bodylength);
			end
		end
	elseif request.state == "headers" then
		print("Reading headers...")
		local pos = startpos;
		local headers, headers_complete = request.responseheaders;
		if not headers then
			headers = {};
			request.responseheaders = headers;
		end
		for line in data:sub(startpos, -1):gmatch("(.-)\r\n") do
			startpos = startpos + #line + 2;
			local k, v = line:match("(%S+): (.+)");
			if k and v then
				headers[k:lower()] = v;
				--print("Header: "..k:lower().." = "..v);
			elseif #line == 0 then
				headers_complete = true;
				break;
			else
				print("Unhandled header line: "..line);
			end
		end
		if not headers_complete then return; end
		-- Reached the end of the headers
		if not expectbody(request, request.code) then
			request.callback(nil, request.code, request);
			return;
		end
			request.state = "body";
		if #data > startpos then
			return request_reader(request, data, startpos);
		end
	elseif request.state == "status" then
		print("Reading status...")
		local http, code, text, linelen = data:match("^HTTP/(%S+) (%d+) (.-)\r\n()", startpos);
		code = tonumber(code);
		if not code then
			return request.callback("invalid-status-line", 0, request);
		end
		
		request.code, request.responseversion = code, http;
		
		if request.onlystatus then
			if request.callback then
				request.callback(nil, code, request);
			end
			destroy_request(request);
			return;
		end
		
		request.state = "headers";
		
		if #data > linelen then
			return request_reader(request, data, linelen);
		end
	end
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
	
	local custom_headers, body;
	local default_headers = { ["Host"] = req.host, ["User-Agent"] = "Prosody XMPP Server" }
	
	
	if req.userinfo then
		default_headers["Authorization"] = "Basic "..mime.b64(req.userinfo);
	end
	
	if ex then
		custom_headers = ex.headers;
		req.onlystatus = ex.onlystatus;
		body = ex.body;
		if body then
			req.method = "POST ";
			default_headers["Content-Length"] = tostring(#body);
			default_headers["Content-Type"] = "application/x-www-form-urlencoded";
		end
		if ex.method then req.method = ex.method; end
	end
	
	req.handler, req.conn = server.wrapclient(socket.tcp(), req.host, req.port or 80, listener, "*a");
	req.write = req.handler.write;
	req.conn:settimeout(0);
	local ok, err = req.conn:connect(req.host, req.port or 80);
	if not ok and err ~= "timeout" then
		callback(nil, 0, req);
		return nil, err;
	end
	
	local request_line = { req.method or "GET", " ", req.path, " HTTP/1.1\r\n" };
	
	if req.query then
		t_insert(request_line, 4, "?");
		t_insert(request_line, 5, req.query);
	end
	
	req.write(t_concat(request_line));
	local t = { [2] = ": ", [4] = "\r\n" };
	if custom_headers then
		for k, v in pairs(custom_headers) do
			t[1], t[3] = k, v;
			req.write(t_concat(t));
			default_headers[k] = nil;
		end
	end
	
	for k, v in pairs(default_headers) do
		t[1], t[3] = k, v;
		req.write(t_concat(t));
		default_headers[k] = nil;
	end
	req.write("\r\n");
	
	if body then
		req.write(body);
	end
	
	req.callback = function (content, code, request) log("debug", "Calling callback, status %s", code or "---"); return select(2, xpcall(function () return callback(content, code, request) end, handleerr)); end
	req.reader = request_reader;
	req.state = "status";
	
	listener.register_request(req.handler, req);

	return req;
end

function destroy_request(request)
	if request.conn then
		request.handler.close()
		listener.disconnect(request.conn, "closed");
	end
end

_M.urlencode = urlencode;

return _M;
