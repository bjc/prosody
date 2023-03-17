-- Prosody IM
-- Copyright (C) 2012 Florian Zeitz
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local t_concat = table.concat;

local http = require "prosody.net.http";
local frames = require "prosody.net.websocket.frames";
local base64 = require "prosody.util.encodings".base64;
local sha1 = require "prosody.util.hashes".sha1;
local random_bytes = require "prosody.util.random".bytes;
local timer = require "prosody.util.timer";
local log = require "prosody.util.logger".init "websocket";

local close_timeout = 3; -- Seconds to wait after sending close frame until closing connection.

local websockets = {};

local websocket_listeners = {};
function websocket_listeners.ondisconnect(conn, err)
	local s = websockets[conn];
	if not s then return; end
	websockets[conn] = nil;
	if s.close_timer then
		timer.stop(s.close_timer);
		s.close_timer = nil;
	end
	s.readyState = 3;
	if s.close_code == nil and s.onerror then s:onerror(err); end
	if s.onclose then s:onclose(s.close_code, s.close_message or err); end
end

function websocket_listeners.ondetach(conn)
	websockets[conn] = nil;
end

local function fail(s, code, reason)
	log("warn", "WebSocket connection failed, closing. %d %s", code, reason);
	s:close(code, reason);
	s.conn:close();
	return false
end

function websocket_listeners.onincoming(conn, buffer, err) -- luacheck: ignore 212/err
	local s = websockets[conn];
	s.readbuffer = s.readbuffer..buffer;
	while true do
		local frame, len = frames.parse(s.readbuffer);
		if frame == nil then break end
		s.readbuffer = s.readbuffer:sub(len+1);

		log("debug", "Websocket received frame: opcode=%0x, %i bytes", frame.opcode, #frame.data);

		-- Error cases
		if frame.RSV1 or frame.RSV2 or frame.RSV3 then -- Reserved bits non zero
			return fail(s, 1002, "Reserved bits not zero");
		end

		if frame.opcode < 0x8 then
			local databuffer = s.databuffer;
			if frame.opcode == 0x0 then -- Continuation frames
				if not databuffer then
					return fail(s, 1002, "Unexpected continuation frame");
				end
				databuffer[#databuffer+1] = frame.data;
			elseif frame.opcode == 0x1 or frame.opcode == 0x2 then -- Text or Binary frame
				if databuffer then
					return fail(s, 1002, "Continuation frame expected");
				end
				databuffer = {type=frame.opcode, frame.data};
				s.databuffer = databuffer;
			else
				return fail(s, 1002, "Reserved opcode");
			end
			if frame.FIN then
				s.databuffer = nil;
				if s.onmessage then
					s:onmessage(t_concat(databuffer), databuffer.type);
				end
			end
		else -- Control frame
			if frame.length > 125 then -- Control frame with too much payload
				return fail(s, 1002, "Payload too large");
			elseif not frame.FIN then -- Fragmented control frame
				return fail(s, 1002, "Fragmented control frame");
			end
			if frame.opcode == 0x8 then -- Close request
				if frame.length == 1 then
					return fail(s, 1002, "Close frame with payload, but too short for status code");
				end
				local status_code, message = frames.parse_close(frame.data);
				if status_code == nil then
					--[[ RFC 6455 7.4.1
					1005 is a reserved value and MUST NOT be set as a status code in a
					Close control frame by an endpoint.  It is designated for use in
					applications expecting a status code to indicate that no status
					code was actually present.
					]]
					status_code = 1005
				elseif status_code < 1000 then
					return fail(s, 1002, "Closed with invalid status code");
				elseif ((status_code > 1003 and status_code < 1007) or status_code > 1011) and status_code < 3000 then
					return fail(s, 1002, "Closed with reserved status code");
				end
				s.close_code, s.close_message = status_code, message;
				s:close(1000);
				return true;
			elseif frame.opcode == 0x9 then -- Ping frame
				frame.opcode = 0xA;
				frame.MASK = true; -- RFC 6455 6.1.5: If the data is being sent by the client, the frame(s) MUST be masked
				conn:write(frames.build(frame));
			elseif frame.opcode == 0xA then -- Pong frame
				log("debug", "Received unexpected pong frame: %s", frame.data);
			else
				return fail(s, 1002, "Reserved opcode");
			end
		end
	end
	return true;
end

local websocket_methods = {};
local function close_timeout_cb(now, timerid, s) -- luacheck: ignore 212/now 212/timerid
	s.close_timer = nil;
	log("warn", "Close timeout waiting for server to close, closing manually.");
	s.conn:close();
end
function websocket_methods:close(code, reason)
	if self.readyState < 2 then
		code = code or 1000;
		log("debug", "closing WebSocket with code %i: %s" , code , reason);
		self.readyState = 2;
		local conn = self.conn;
		conn:write(frames.build_close(code, reason, true));
		-- Do not close socket straight away, wait for acknowledgement from server.
		self.close_timer = timer.add_task(close_timeout, close_timeout_cb, self);
	elseif self.readyState == 2 then
		log("debug", "tried to close a closing WebSocket, closing the raw socket.");
		-- Stop timer
		if self.close_timer then
			timer.stop(self.close_timer);
			self.close_timer = nil;
		end
		local conn = self.conn;
		conn:close();
	else
		log("debug", "tried to close a closed WebSocket, ignoring.");
	end
end
function websocket_methods:send(data, opcode)
	if self.readyState < 1 then
		return nil, "WebSocket not open yet, unable to send data.";
	elseif self.readyState >= 2 then
		return nil, "WebSocket closed, unable to send data.";
	end
	if opcode == "text" or opcode == nil then
		opcode = 0x1;
	elseif opcode == "binary" then
		opcode = 0x2;
	end
	local frame = {
		FIN = true;
		MASK = true; -- RFC 6455 6.1.5: If the data is being sent by the client, the frame(s) MUST be masked
		opcode = opcode;
		data = tostring(data);
	};
	log("debug", "WebSocket sending frame: opcode=%0x, %i bytes", frame.opcode, #frame.data);
	return self.conn:write(frames.build(frame));
end

local websocket_metatable = {
	__index = websocket_methods;
};

local function connect(url, ex, listeners)
	ex = ex or {};

	--[[RFC 6455 4.1.7:
		The request MUST include a header field with the name
	|Sec-WebSocket-Key|.  The value of this header field MUST be a
	nonce consisting of a randomly selected 16-byte value that has
	been base64-encoded (see Section 4 of [RFC4648]).  The nonce
	MUST be selected randomly for each connection.
	]]
	local key = base64.encode(random_bytes(16));

	-- Either a single protocol string or an array of protocol strings.
	local protocol = ex.protocol;
	if type(protocol) == "string" then
		protocol = { protocol, [protocol] = true };
	elseif type(protocol) == "table" and protocol[1] then
		for _, v in ipairs(protocol) do
			protocol[v] = true;
		end
	else
		protocol = nil;
	end

	local headers = {
		["Upgrade"] = "websocket";
		["Connection"] = "Upgrade";
		["Sec-WebSocket-Key"] = key;
		["Sec-WebSocket-Protocol"] = protocol and t_concat(protocol, ", ");
		["Sec-WebSocket-Version"] = "13";
		["Sec-WebSocket-Extensions"] = ex.extensions;
	}
	if ex.headers then
		for k,v in pairs(ex.headers) do
			headers[k] = v;
		end
	end

	local s = setmetatable({
		readbuffer = "";
		databuffer = nil;
		conn = nil;
		close_code = nil;
		close_message = nil;
		close_timer = nil;
		readyState = 0;
		protocol = nil;

		url = url;

		onopen = listeners.onopen;
		onclose = listeners.onclose;
		onmessage = listeners.onmessage;
		onerror = listeners.onerror;
	}, websocket_metatable);

	local http_url = url:gsub("^(ws)", "http");
	local http_req = http.request(http_url, { -- luacheck: ignore 211/http_req
		method = "GET";
		headers = headers;
		sslctx = ex.sslctx;
		insecure = ex.insecure;
	}, function(b, c, r, http_req)
		if c ~= 101
		   or r.headers["connection"]:lower() ~= "upgrade"
		   or r.headers["upgrade"] ~= "websocket"
		   or r.headers["sec-websocket-accept"] ~= base64.encode(sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		   or (protocol and not protocol[r.headers["sec-websocket-protocol"]])
		   then
			s.readyState = 3;
			log("warn", "WebSocket connection to %s failed: %s", url, b);
			if s.onerror then s:onerror("connecting-failed"); end
			return;
		end

		s.protocol = r.headers["sec-websocket-protocol"];

		-- Take possession of socket from http
		local conn = http_req.conn;
		http_req.conn = nil;
		s.conn = conn;
		websockets[conn] = s;
		conn:setlistener(websocket_listeners);

		log("debug", "WebSocket connected successfully to %s", url);
		s.readyState = 1;
		if s.onopen then s:onopen(); end
		websocket_listeners.onincoming(conn, b);
	end);

	return s;
end

return {
	connect = connect;
};
