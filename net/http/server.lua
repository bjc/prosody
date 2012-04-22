
local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;
local parser_new = require "net.http.parser".new;
local events = require "util.events".new();
local addserver = require "net.server".addserver;
local log = require "util.logger".init("http.server");
local os_date = os.date;
local pairs = pairs;
local s_upper = string.upper;
local setmetatable = setmetatable;
local xpcall = xpcall;
local debug = debug;
local tostring = tostring;
local codes = require "net.http.codes";
local _G = _G;
local legacy_httpserver = require "net.httpserver";

local _M = {};

local sessions = {};
local handlers = {};

local listener = {};

local handle_request;
local _1, _2, _3;
local function _handle_request() return handle_request(_1, _2, _3); end
local function _traceback_handler(err) log("error", "Traceback[http]: %s: %s", tostring(err), debug.traceback()); end

function listener.onconnect(conn)
	local secure = conn:ssl() and true or nil;
	local pending = {};
	local waiting = false;
	local function process_next(last_response)
		--if waiting then log("debug", "can't process_next, waiting"); return; end
		if sessions[conn] and #pending > 0 then
			local request = t_remove(pending);
			--log("debug", "process_next: %s", request.path);
			waiting = true;
			--handle_request(conn, request, process_next);
			_1, _2, _3 = conn, request, process_next;
			if not xpcall(_handle_request, _traceback_handler) then
				conn:write("HTTP/1.0 503 Internal Server Error\r\n\r\nAn error occured during the processing of this request.");
				conn:close();
			end
		else
			--log("debug", "ready for more");
			waiting = false;
		end
	end
	local function success_cb(request)
		--log("debug", "success_cb: %s", request.path);
		request.secure = secure;
		t_insert(pending, request);
		if not waiting then
			process_next();
		end
	end
	local function error_cb(err)
		log("debug", "error_cb: %s", err or "<nil>");
		-- FIXME don't close immediately, wait until we process current stuff
		-- FIXME if err, send off a bad-request response
		sessions[conn] = nil;
		conn:close();
	end
	sessions[conn] = parser_new(success_cb, error_cb);
end

function listener.ondisconnect(conn)
	sessions[conn] = nil;
end

function listener.onincoming(conn, data)
	sessions[conn]:feed(data);
end

local headerfix = setmetatable({}, {
	__index = function(t, k)
		local v = "\r\n"..k:gsub("_", "-"):gsub("%f[%w].", s_upper)..": ";
		t[k] = v;
		return v;
	end
});

function _M.hijack_response(response, listener)
	error("TODO");
end
function handle_request(conn, request, finish_cb)
	--log("debug", "handler: %s", request.path);
	local headers = {};
	for k,v in pairs(request.headers) do headers[k:gsub("-", "_")] = v; end
	request.headers = headers;
	request.conn = conn;

	local date_header = os_date('!%a, %d %b %Y %H:%M:%S GMT'); -- FIXME use
	local conn_header = request.headers.connection;
	local keep_alive = conn_header == "Keep-Alive" or (request.httpversion == "1.1" and conn_header ~= "close");

	local response = {
		request = request;
		status_code = 200;
		headers = { date = date_header, connection = (keep_alive and "Keep-Alive" or "close") };
		conn = conn;
		send = _M.send_response;
		finish_cb = finish_cb;
	};

	if not request.headers.host then
		response.status_code = 400;
		response.headers.content_type = "text/html";
		response:send("<html><head>400 Bad Request</head><body>400 Bad Request: No Host header.</body></html>");
	else
		-- TODO call handler
		--response.headers.content_type = "text/plain";
		--response:send("host="..(request.headers.host or "").."\npath="..request.path.."\n"..(request.body or ""));
		local host = request.headers.host;
		if host then
			host = host:match("[^:]*"):lower();
			local event = request.method.." "..host..request.path:match("[^?]*");
			local payload = { request = request, response = response };
			--[[repeat
				if events.fire_event(event, payload) ~= nil then return; end
				event = (event:sub(-1) == "/") and event:sub(1, -1) or event:gsub("[^/]*$", "");
				if event:sub(-1) == "/" then
					event = event:sub(1, -1);
				else
					event = event:gsub("[^/]*$", "");
				end
			until not event:find("/", 1, true);]]
			--log("debug", "Event: %s", event);
			if events.fire_event(event, payload) ~= nil then return; end
			-- TODO try adding/stripping / at the end, but this needs to work via an HTTP redirect
			if events.fire_event("*", payload) ~= nil then return; end
		end

		-- if handler not called, fallback to legacy httpserver handlers
		_M.legacy_handler(request, response);
	end
end
function _M.send_response(response, body)
	local status_line = "HTTP/"..response.request.httpversion.." "..(response.status or codes[response.status_code]);
	local headers = response.headers;
	body = body or "";
	headers.content_length = #body;

	local output = { status_line };
	for k,v in pairs(headers) do
		t_insert(output, headerfix[k]..v);
	end
	t_insert(output, "\r\n\r\n");
	t_insert(output, body);

	response.conn:write(t_concat(output));
	if headers.connection == "Keep-Alive" then
		response:finish_cb();
	else
		response.conn:close();
	end
end
function _M.legacy_handler(request, response)
	log("debug", "Invoking legacy handler");
	local base = request.path:match("^/([^/?]+)");
	local legacy_server = legacy_httpserver and legacy_httpserver.new.http_servers[5280];
	local handler = legacy_server and legacy_server.handlers[base];
	if not handler then handler = legacy_httpserver and legacy_httpserver.set_default_handler.default_handler; end
	if handler then
		-- add legacy properties to request object
		request.url = { path = request.path };
		request.handler = response.conn;
		request.id = tostring{}:match("%x+$");
		local headers = {};
		for k,v in pairs(request.headers) do
			headers[k:gsub("_", "-")] = v;
		end
		request.headers = headers;
		function request:send(resp)
			if self.destroyed then return; end
			if resp.body or resp.headers then
				if resp.headers then
					for k,v in pairs(resp.headers) do response.headers[k] = v; end
				end
				response:send(resp.body)
			else
				response:send(resp)
			end
			self.sent = true;
			self:destroy();
		end
		function request:destroy()
			if self.destroyed then return; end
			if not self.sent then return self:send(""); end
			self.destroyed = true;
			if self.on_destroy then
				log("debug", "Request has destroy callback");
				self:on_destroy();
			else
				log("debug", "Request has no destroy callback");
			end
		end
		local r = handler(request.method, request.body, request);
		if r ~= true then
			request:send(r);
		end
	else
		log("debug", "No handler found");
		response.status_code = 404;
		response.headers.content_type = "text/html";
		response:send("<html><head><title>404 Not Found</title></head><body>404 Not Found: No such page.</body></html>");
	end
end

function _M.add_handler(event, handler, priority)
	events.add_handler(event, handler, priority);
end
function _M.remove_handler(event, handler)
	events.remove_handler(event, handler);
end

function _M.listen_on(port, interface, ssl)
	addserver(interface or "*", port, listener, "*a", ssl);
end

_M.listener = listener;
_M.codes = codes;
return _M;
