
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
local traceback = debug.traceback;
local tostring = tostring;
local cache = require "util.cache";
local codes = require "net.http.codes";
local blocksize = 2^16;

local _M = {};

local sessions = {};
local incomplete = {};
local listener = {};
local hosts = {};
local default_host;

local function is_wildcard_event(event)
	return event:sub(-2, -1) == "/*";
end
local function is_wildcard_match(wildcard_event, event)
	return wildcard_event:sub(1, -2) == event:sub(1, #wildcard_event-1);
end

local _handlers = events._handlers;
local recent_wildcard_events = cache.new(10000, function (key, value)
	rawset(_handlers, key, nil);
end);

local event_map = events._event_map;
setmetatable(events._handlers, {
	-- Called when firing an event that doesn't exist (but may match a wildcard handler)
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
		if not event_map[curr_event] then -- Only wildcard handlers match, if any
			recent_wildcard_events:set(curr_event, true);
		end
		return handlers_array;
	end;
	__newindex = function (handlers, curr_event, handlers_array)
		if handlers_array == nil
		and is_wildcard_event(curr_event) then
			-- Invalidate the indexes of all matching events
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
local function _traceback_handler(err) last_err = err; log("error", "Traceback[httpserver]: %s", traceback(tostring(err), 2)); end
events.add_handler("http-error", function (error)
	return "Error processing request: "..codes[error.code]..". Check your error log for more information.";
end, -1);

function listener.onconnect(conn)
	local secure = conn:ssl() and true or nil;
	local pending = {};
	local waiting = false;
	local function process_next()
		if waiting then return; end -- log("debug", "can't process_next, waiting");
		waiting = true;
		while sessions[conn] and #pending > 0 do
			local request = t_remove(pending);
			--log("debug", "process_next: %s", request.path);
			--handle_request(conn, request, process_next);
			_1, _2, _3 = conn, request, process_next;
			if not xpcall(_handle_request, _traceback_handler) then
				conn:write("HTTP/1.0 500 Internal Server Error\r\n\r\n"..events.fire_event("http-error", { code = 500, private_message = last_err }));
				conn:close();
			end
		end
		--log("debug", "ready for more");
		waiting = false;
	end
	local function success_cb(request)
		--log("debug", "success_cb: %s", request.path);
		if waiting then
			log("error", "http connection handler is not reentrant: %s", request.path);
			assert(false, "http connection handler is not reentrant");
		end
		request.secure = secure;
		t_insert(pending, request);
		process_next();
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
	incomplete[conn] = nil;
	sessions[conn] = nil;
end

function listener.ondetach(conn)
	sessions[conn] = nil;
	incomplete[conn] = nil;
end

function listener.onincoming(conn, data)
	sessions[conn]:feed(data);
end

function listener.ondrain(conn)
	local response = incomplete[conn];
	if response and response._send_more then
		response._send_more();
	end
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
	conn_header = conn_header and ","..conn_header:gsub("[ \t]", ""):lower().."," or ""
	local httpversion = request.httpversion
	local persistent = conn_header:find(",keep-alive,", 1, true)
		or (httpversion == "1.1" and not conn_header:find(",close,", 1, true));

	local response_conn_header;
	if persistent then
		response_conn_header = "Keep-Alive";
	else
		response_conn_header = httpversion == "1.1" and "close" or nil
	end

	local response = {
		request = request;
		status_code = 200;
		headers = { date = date_header, connection = response_conn_header };
		persistent = persistent;
		conn = conn;
		send = _M.send_response;
		send_file = _M.send_file;
		done = _M.finish_response;
		finish_cb = finish_cb;
	};
	conn._http_open_response = response;

	local host = (request.headers.host or ""):match("[^:]+");

	-- Some sanity checking
	local err_code, err;
	if not request.path then
		err_code, err = 400, "Invalid path";
	elseif not hosts[host] then
		if hosts[default_host] then
			host = default_host;
		elseif host then
			err_code, err = 404, "Unknown host: "..host;
		else
			err_code, err = 400, "Missing or invalid 'Host' header";
		end
	end

	if err then
		response.status_code = err_code;
		response:send(events.fire_event("http-error", { code = err_code, message = err }));
		return;
	end

	local event = request.method.." "..host..request.path:match("[^?]*");
	local payload = { request = request, response = response };
	log("debug", "Firing event: %s", event);
	local result = events.fire_event(event, payload);
	if result ~= nil then
		if result ~= true then
			local body;
			local result_type = type(result);
			if result_type == "number" then
				response.status_code = result;
				if result >= 400 then
					body = events.fire_event("http-error", { code = result });
				end
			elseif result_type == "string" then
				body = result;
			elseif result_type == "table" then
				for k, v in pairs(result) do
					if k ~= "headers" then
						response[k] = v;
					else
						for header_name, header_value in pairs(v) do
							response.headers[header_name] = header_value;
						end
					end
				end
			end
			response:send(body);
		end
		return;
	end

	-- if handler not called, return 404
	response.status_code = 404;
	response:send(events.fire_event("http-error", { code = 404 }));
end
local function prepare_header(response)
	local status_line = "HTTP/"..response.request.httpversion.." "..(response.status or codes[response.status_code]);
	local headers = response.headers;
	local output = { status_line };
	for k,v in pairs(headers) do
		t_insert(output, headerfix[k]..v);
	end
	t_insert(output, "\r\n\r\n");
	return output;
end
_M.prepare_header = prepare_header;
function _M.send_response(response, body)
	if response.finished then return; end
	body = body or response.body or "";
	response.headers.content_length = #body;
	local output = prepare_header(response);
	t_insert(output, body);
	response.conn:write(t_concat(output));
	response:done();
end
function _M.send_file(response, f)
	if response.finished then return; end
	local chunked = not response.headers.content_length;
	if chunked then response.headers.transfer_encoding = "chunked"; end
	incomplete[response.conn] = response;
	response._send_more = function ()
		if response.finished then
			incomplete[response.conn] = nil;
			return;
		end
		local chunk = f:read(blocksize);
		if chunk then
			if chunked then
				chunk = ("%x\r\n%s\r\n"):format(#chunk, chunk);
			end
			-- io.write("."); io.flush();
			response.conn:write(chunk);
		else
			if chunked then
				response.conn:write("0\r\n\r\n");
			end
			-- io.write("\n");
			if f.close then f:close(); end
			incomplete[response.conn] = nil;
			return response:done();
		end
	end
	response.conn:write(t_concat(prepare_header(response)));
	return true;
end
function _M.finish_response(response)
	if response.finished then return; end
	response.finished = true;
	response.conn._http_open_response = nil;
	if response.on_destroy then
		response:on_destroy();
		response.on_destroy = nil;
	end
	if response.persistent then
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
	return addserver(interface or "*", port, listener, "*a", ssl);
end
function _M.add_host(host)
	hosts[host] = true;
end
function _M.remove_host(host)
	hosts[host] = nil;
end
function _M.set_default_host(host)
	default_host = host;
end
function _M.fire_event(event, ...)
	return events.fire_event(event, ...);
end

_M.listener = listener;
_M.codes = codes;
_M._events = events;
return _M;
