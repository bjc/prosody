-- Prosody IM
-- Copyright (C) 2012-2014 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 431/log

module:set_global();

local add_task = require "prosody.util.timer".add_task;
local add_filter = require "prosody.util.filters".add_filter;
local sha1 = require "prosody.util.hashes".sha1;
local base64 = require "prosody.util.encodings".base64.encode;
local st = require "prosody.util.stanza";
local parse_xml = require "prosody.util.xml".parse;
local contains_token = require "prosody.util.http".contains_token;
local portmanager = require "prosody.core.portmanager";
local sm_destroy_session = require"prosody.core.sessionmanager".destroy_session;
local log = module._log;
local dbuffer = require "prosody.util.dbuffer";

local websocket_frames = require"prosody.net.websocket.frames";
local parse_frame = websocket_frames.parse;
local build_frame = websocket_frames.build;
local build_close = websocket_frames.build_close;
local parse_close = websocket_frames.parse_close;

local t_concat = table.concat;

local stanza_size_limit = module:get_option_integer("c2s_stanza_size_limit", 1024 * 256, 10000);
local frame_buffer_limit = module:get_option_integer("websocket_frame_buffer_limit", 2 * stanza_size_limit, 0);
local frame_fragment_limit = module:get_option_integer("websocket_frame_fragment_limit", 8, 0);
local stream_close_timeout = module:get_option_period("c2s_close_timeout", 5);
local consider_websocket_secure = module:get_option_boolean("consider_websocket_secure");
local cross_domain = module:get_option("cross_domain_websocket");
if cross_domain ~= nil then
	module:log("info", "The 'cross_domain_websocket' option has been deprecated");
end
local xmlns_framing = "urn:ietf:params:xml:ns:xmpp-framing";
local xmlns_streams = "http://etherx.jabber.org/streams";
local xmlns_client = "jabber:client";
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};

module:depends("c2s")
local sessions = module:shared("c2s/sessions");
local c2s_listener = portmanager.get_service("c2s").listener;

--- Session methods
local function session_open_stream(session, from, to)
	local attr = {
		xmlns = xmlns_framing,
		["xml:lang"] = "en",
		version = "1.0",
		id = session.streamid or "",
		from = from or session.host, to = to,
	};
	if session.stream_attrs then
		session:stream_attrs(from, to, attr)
	end
	session.send(st.stanza("open", attr));
end

local function session_close(session, reason)
	local log = session.log or log;
	local close_event_payload = { session = session, reason = reason };
	module:context(session.host):fire_event("pre-session-close", close_event_payload);
	reason = close_event_payload.reason;
	if session.conn then
		if session.notopen then
			session:open_stream();
		end
		if reason then -- nil == no err, initiated by us, false == initiated by client
			local stream_error = st.stanza("stream:error");
			if type(reason) == "string" then -- assume stream error
				stream_error:tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' });
			elseif st.is_stanza(reason) then
				stream_error = reason;
			elseif type(reason) == "table" then
				if reason.condition then
					stream_error:tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stream_error:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stream_error:add_child(reason.extra);
					end
				end
			end
			stream_error = tostring(stream_error);
			log("debug", "Disconnecting client, <stream:error> is: %s", stream_error);
			session.send(stream_error);
		end

		session.send(st.stanza("close", { xmlns = xmlns_framing }));
		function session.send() return false; end

		local reason_text = (reason and (reason.name or reason.text or reason.condition)) or reason;
		session.log("debug", "c2s stream for %s closed: %s", session.full_jid or session.ip or "<unknown>", reason_text or "session closed");

		-- Authenticated incoming stream may still be sending us stanzas, so wait for </stream:stream> from remote
		local conn = session.conn;
		if reason_text == nil and not session.notopen and session.type == "c2s" then
			-- Grace time to process data from authenticated cleanly-closed stream
			add_task(stream_close_timeout, function ()
				if not session.destroyed then
					session.log("warn", "Failed to receive a stream close response, closing connection anyway...");
					sm_destroy_session(session, reason_text);
					if conn then
						conn:write(build_close(1000, "Stream closed"));
						conn:close();
					end
				end
			end);
		else
			sm_destroy_session(session, reason_text);
			if conn then
				conn:write(build_close(1000, "Stream closed"));
				conn:close();
			end
		end
	else
		local reason_text = (reason and (reason.name or reason.text or reason.condition)) or reason;
		sm_destroy_session(session, reason_text);
	end
end


--- Filters
local function filter_open_close(data)
	if not data:find(xmlns_framing, 1, true) then return data; end

	local oc = parse_xml(data);
	if not oc then return data; end
	if oc.attr.xmlns ~= xmlns_framing then return data; end
	if oc.name == "close" then return "</stream:stream>"; end
	if oc.name == "open" then
		oc.name = "stream:stream";
		oc.attr.xmlns = nil;
		oc.attr["xmlns:stream"] = xmlns_streams;
		return oc:top_tag();
	end

	return data;
end

local default_get_response_text = "It works! Now point your WebSocket client to this URL to connect to Prosody."
local websocket_get_response_text = module:get_option_string("websocket_get_response_text", default_get_response_text)

local default_get_response_body = [[<!DOCTYPE html><html><head><title>Websocket</title></head><body>
<p>]]..websocket_get_response_text..[[</p>
</body></html>]]
local websocket_get_response_body = module:get_option_string("websocket_get_response_body", default_get_response_body)

local function validate_frame(frame, max_length)
	local opcode, length = frame.opcode, frame.length;

	if max_length and length > max_length then
		return false, 1009, "Payload too large";
	end

	-- Error cases
	if frame.RSV1 or frame.RSV2 or frame.RSV3 then -- Reserved bits non zero
		return false, 1002, "Reserved bits not zero";
	end

	if opcode == 0x8 and frame.data then -- close frame
		if length == 1 then
			return false, 1002, "Close frame with payload, but too short for status code";
		elseif length >= 2 then
			local status_code = parse_close(frame.data)
			if status_code < 1000 then
				return false, 1002, "Closed with invalid status code";
			elseif ((status_code > 1003 and status_code < 1007) or status_code > 1011) and status_code < 3000 then
				return false, 1002, "Closed with reserved status code";
			end
		end
	end

	if opcode >= 0x8 then
		if length > 125 then -- Control frame with too much payload
			return false, 1002, "Payload too large";
		end

		if not frame.FIN then -- Fragmented control frame
			return false, 1002, "Fragmented control frame";
		end
	end

	if (opcode > 0x2 and opcode < 0x8) or (opcode > 0xA) then
		return false, 1002, "Reserved opcode";
	end

	-- Check opcode
	if opcode == 0x2 then -- Binary frame
		return false, 1003, "Only text frames are supported, RFC 7395 3.2";
	elseif opcode == 0x8 then -- Close request
		return false, 1000, "Goodbye";
	end

	-- Other (XMPP-specific) validity checks
	if not frame.FIN then
		return false, 1003, "Continuation frames are not supported, RFC 7395 3.3.3";
	end
	if opcode == 0x01 and frame.data and frame.data:byte(1, 1) ~= 60 then
		return false, 1007, "Invalid payload start character, RFC 7395 3.3.3";
	end

	return true;
end


function handle_request(event)
	local request, response = event.request, event.response;
	local conn = response.conn;

	conn.starttls = false; -- Prevent mod_tls from believing starttls can be done

	if not request.headers.sec_websocket_key or request.method ~= "GET" then
		return module:fire_event("http-message", {
			response = event.response;
			---
			title = "Prosody WebSocket endpoint";
			message = websocket_get_response_text;
			warning = not (consider_websocket_secure or request.secure) and "This endpoint is not considered secure!" or nil;
		}) or websocket_get_response_body;
		end

	local wants_xmpp = contains_token(request.headers.sec_websocket_protocol or "", "xmpp");

	if not wants_xmpp then
		module:log("debug", "Client didn't want to talk XMPP, list of protocols was %s", request.headers.sec_websocket_protocol or "(empty)");
		return 501;
	end

	local function websocket_close(code, message)
		conn:write(build_close(code, message));
		conn:close();
	end

	local function websocket_handle_error(session, code, message)
		if code == 1009 then -- stanza size limit exceeded
			-- we close the session, rather than the connection,
			-- otherwise a resuming client will simply resend the
			-- offending stanza
			session:close({ condition = "policy-violation", text = "stanza too large" });
		else
			websocket_close(code, message);
		end
	end

	local function handle_frame(frame)
		module:log("debug", "Websocket received frame: opcode=%0x, %i bytes", frame.opcode, #frame.data);

		-- Check frame makes sense
		local frame_ok, err_status, err_text = validate_frame(frame, stanza_size_limit);
		if not frame_ok then
			return frame_ok, err_status, err_text;
		end

		local opcode = frame.opcode;
		if opcode == 0x9 then -- Ping frame
			frame.opcode = 0xA;
			frame.MASK = false; -- Clients send masked frames, servers don't, see #1484
			conn:write(build_frame(frame));
			return "";
		elseif opcode == 0xA then -- Pong frame, MAY be sent unsolicited, eg as keepalive
			return "";
		elseif opcode ~= 0x1 then -- Not text frame (which is all we support)
			log("warn", "Received frame with unsupported opcode %i", opcode);
			return "";
		end

		return frame.data;
	end

	conn:setlistener(c2s_listener);
	c2s_listener.onconnect(conn);

	local session = sessions[conn];

	-- Use upstream IP if a HTTP proxy was used
	-- See mod_http and #540
	session.ip = request.ip;

	session.secure = consider_websocket_secure or request.secure or session.secure;
	session.websocket_request = request;

	session.open_stream = session_open_stream;
	session.close = session_close;

	local frameBuffer = dbuffer.new(frame_buffer_limit, frame_fragment_limit);
	add_filter(session, "bytes/in", function(data)
		if not frameBuffer:write(data) then
			session.log("warn", "websocket frame buffer full - terminating session");
			session:close({ condition = "resource-constraint", text = "frame buffer exceeded" });
			return;
		end

		local cache = {};
		local frame, length, partial = parse_frame(frameBuffer);

		while frame do
			frameBuffer:discard(length);
			local result, err_status, err_text = handle_frame(frame);
			if not result then
				websocket_handle_error(session, err_status, err_text);
				break;
			end
			cache[#cache+1] = filter_open_close(result);
			frame, length, partial = parse_frame(frameBuffer);
		end

		if partial then
			-- The header of the next frame is already in the buffer, run
			-- some early validation here
			local frame_ok, err_status, err_text = validate_frame(partial, stanza_size_limit);
			if not frame_ok then
				websocket_handle_error(session, err_status, err_text);
			end
		end

		return t_concat(cache, "");
	end);

	add_filter(session, "stanzas/out", function(stanza)
		stanza = st.clone(stanza);
		local attr = stanza.attr;
		attr.xmlns = attr.xmlns or xmlns_client;
		if stanza.name:find("^stream:") then
			attr["xmlns:stream"] = attr["xmlns:stream"] or xmlns_streams;
		end
		return stanza;
	end, -1000);

	add_filter(session, "bytes/out", function(data)
		return build_frame({ FIN = true, opcode = 0x01, data = tostring(data)});
	end);

	response.status_code = 101;
	response.headers.upgrade = "websocket";
	response.headers.connection = "Upgrade";
	response.headers.sec_webSocket_accept = base64(sha1(request.headers.sec_websocket_key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
	response.headers.sec_webSocket_protocol = "xmpp";

	module:fire_event("websocket-session", { session = session, request = request });

	session.log("debug", "Sending WebSocket handshake");

	return "";
end

local function keepalive(event)
	local session = event.session;
	if session.open_stream == session_open_stream then
		return session.conn:write(build_frame({ opcode = 0x9, FIN = true }));
	end
end

function module.add_host(module)
	module:hook("c2s-read-timeout", keepalive, -0.9);

	module:depends("http");
	module:provides("http", {
		name = "websocket";
		default_path = "xmpp-websocket";
		cors = {
			enabled = true;
		};
		route = {
			["GET"] = handle_request;
			["GET /"] = handle_request;
		};
	});

	if module.host ~= "*" then
		module:depends("http_altconnect", true);
	end

	module:hook("c2s-read-timeout", keepalive, -0.9);
end

if require"prosody.core.modulemanager".get_modules_for_host("*"):contains(module.name) then
	module:add_host();
end
