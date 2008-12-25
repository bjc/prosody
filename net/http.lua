
local socket = require "socket"
local mime = require "mime"
local url = require "socket.url"

local server = require "net.server"

local connlisteners_get = require "net.connlisteners".get;
local listener = connlisteners_get("httpclient") or error("No httpclient listener!");

local t_insert, t_concat = table.insert, table.concat;
local tonumber, tostring, pairs = tonumber, tostring, pairs;
local print = function () end

local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = char(tonumber("0x"..k)); return t[k]; end });
local urlencode = function (s) return s and (s:gsub("%W", function (c) return string.format("%%%02x", c:byte()); end)); end

module "http"

local function expectbody(reqt, code)
    if reqt.method == "HEAD" then return nil end
    if code == 204 or code == 304 then return nil end
    if code >= 100 and code < 200 then return nil end
    return 1
end

local function request_reader(request, data, startpos)
	if not data then
		if request.body then
			request.callback(t_concat(request.body), request.code, request);
		else
			-- Error.. connection was closed prematurely
			request.callback("connection-closed", 0, request);
		end
		destroy_request(request);
		return;
	end
	if request.state == "body" then
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
				if request.callback then
					request.callback(t_concat(request.body), request.code, request);
				end
			end
			print("", "Have "..request.havebodylength.." bytes out of "..request.bodylength);
		end
	elseif request.state == "headers" then
		print("Reading headers...")
		local pos = startpos;
		local headers = request.responseheaders or {};
		for line in data:sub(startpos, -1):gmatch("(.-)\r\n") do
			startpos = startpos + #line + 2;
			local k, v = line:match("(%S+): (.+)");
			if k and v then
				headers[k:lower()] = v;
				print("Header: "..k:lower().." = "..v);
			elseif #line == 0 then
				request.responseheaders = headers;
				break;
			else
				print("Unhandled header line: "..line);
			end
		end
		-- Reached the end of the headers
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
		
		if request.onlystatus or not expectbody(request, code) then
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

function request(u, ex, callback)
	local req = url.parse(u);
	
	local custom_headers, body;
	local default_headers = { ["Host"] = req.host, ["User-Agent"] = "Prosody XMPP Server" }
	
	
	if req.userinfo then
		default_headers["Authorization"] = "Basic "..mime.b64(req.userinfo);
	end
	
	if ex then
		custom_headers = ex.custom_headers;
		req.onlystatus = ex.onlystatus;
		body = ex.body;
		if body then
			req.method = "POST ";
			default_headers["Content-Length"] = tostring(#body);
			default_headers["Content-Type"] = "application/x-www-form-urlencoded";
		end
		if ex.method then req.method = ex.method; end
	end
	
	req.handler, req.conn = server.wraptcpclient(listener, socket.tcp(), req.host, req.port or 80, 0, "*a");
	req.write = req.handler.write;
	req.conn:settimeout(0);
	local ok, err = req.conn:connect(req.host, req.port or 80);
	if not ok and err ~= "timeout" then
		return nil, err;
	end
	
	req.write((req.method or "GET ")..req.path.." HTTP/1.0\r\n");
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
	
	req.callback = callback;
	req.reader = request_reader;
	req.state = "status"
	
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
