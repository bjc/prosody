
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

local function is_wildcard_event(event)
	return event:sub(-2, -1) == "/*";
end
local function is_wildcard_match(wildcard_event, event)
	return wildcard_event:sub(1, -2) == event:sub(1, #wildcard_event-1);
end

local event_map = events._event_map;
setmetatable(events._handlers, {
	__index = function (handlers, curr_event)
		if is_wildcard_event(curr_event) then return; end -- Wildcard events cannot be fired
		-- Find all handlers that could match this event, sort them
		-- and then put the array into handlers[curr_event] (and return it)
		local matching_handlers_set = {};
		local handlers_array = {};
		for event, handlers_set in pairs(event_map) do
			if event == curr_event or
			is_wildcard_event(event) and is_wildcard_match(event, curr_event) then
				for handler, priority in pairs(handlers_set) do
					matching_handlers_set[handler] = { (select(2, event:gsub("/", "%1"))), is_wildcard_event(event) and 0 or 1, priority };
					table.insert(handlers_array, handler);
				end
			end
		end
		if #handlers_array > 0 then
			table.sort(handlers_array, function(b, a)
				local a_score, b_score = matching_handlers_set[a], matching_handlers_set[b];
				for i = 1, #a_score do
					if a_score[i] ~= b_score[i] then -- If equal, compare next score value
						return a_score[i] < b_score[i];
					end
				end
				return false;
			end);
		else
			handlers_array = false;
		end
		rawset(handlers, curr_event, handlers_array);
		return handlers_array;
	end;
	__newindex = function (handlers, curr_event, handlers_array)
		if handlers_array == nil
		and is_wildcard_event(curr_event) then
			-- Invalidate all matching
			for event in pairs(handlers) do
				if is_wildcard_match(curr_event, event) then
					handlers[event] = nil;
				end
			end
		end
		rawset(handlers, curr_event, handlers_array);
	end;
});

local handle_request;
local _1, _2, _3;
local function _handle_request() return handle_request(_1, _2, _3); end

local last_err;
local function _traceback_handler(err) last_err = err; log("error", "Traceback[http]: %s: %s", tostring(err), debug.traceback()); end
events.add_handler("http-error", function (error)
	return "Error processing request: "..codes[error.code]..". Check your error log for more information.";
end, -1);

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
				conn:write("HTTP/1.0 500 Internal Server Error\r\n\r\n"..events.fire_event("http-error", { code = 500, private_message = last_err }));
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
	local open_response = conn._http_open_response;
	if open_response and open_response.on_destroy then
		open_response.finished = true;
		open_response:on_destroy();
	end
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
	conn._http_open_response = response;

	local err;
	if not request.headers.host then
		err = "No 'Host' header";
	elseif not request.path then
		err = "Invalid path";
	end
	
	if err then
		response.status_code = 400;
		response.headers.content_type = "text/html";
		response:send(events.fire_event("http-error", { code = 400, message = err }));
	else
		local host = request.headers.host;
		if host then
			host = host:match("[^:]*"):lower();
			local event = request.method.." "..host..request.path:match("[^?]*");
			local payload = { request = request, response = response };
			--log("debug", "Firing event: %s", event);
			local result = events.fire_event(event, payload);
			if result ~= nil then
				if result ~= true then
					local code, body = 200, "";
					local result_type = type(result);
					if result_type == "number" then
						response.status_code = result;
						if result >= 400 then
							body = events.fire_event("http-error", { code = result });
						end
					elseif result_type == "string" then
						body = result;
					elseif result_type == "table" then
						body = result.body;
						result.body = nil;
						for k, v in pairs(result) do
							response[k] = v;
						end
					end
					response:send(body);
				end
				return;
			end
		end

		-- if handler not called, return 404
		response.status_code = 404;
		response.headers.content_type = "text/html";
		response:send(events.fire_event("http-error", { code = 404 }));
	end
end
function _M.send_response(response, body)
	if response.finished then return; end
	response.finished = true;
	response.conn._http_open_response = nil;
	
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
	if response.on_destroy then
		response:on_destroy();
		response.on_destroy = nil;
	end
	if headers.connection == "Keep-Alive" then
		response:finish_cb();
	else
		response.conn:close();
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
_M._events = events;
return _M;
