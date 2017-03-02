-- Prosody IM
-- Copyright (C) 2012-2014 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 431/log

module:set_global();

local add_task = require "util.timer".add_task;
local add_filter = require "util.filters".add_filter;
local sha1 = require "util.hashes".sha1;
local base64 = require "util.encodings".base64.encode;
local st = require "util.stanza";
local parse_xml = require "util.xml".parse;
local contains_token = require "util.http".contains_token;
local portmanager = require "core.portmanager";
local sm_destroy_session = require"core.sessionmanager".destroy_session;
local log = module._log;

local websocket_frames = require"net.websocket.frames";
local parse_frame = websocket_frames.parse;
local build_frame = websocket_frames.build;
local build_close = websocket_frames.build_close;
local parse_close = websocket_frames.parse_close;

local t_concat = table.concat;

local stream_close_timeout = module:get_option_number("c2s_close_timeout", 5);
local consider_websocket_secure = module:get_option_boolean("consider_websocket_secure");
local cross_domain = module:get_option_set("cross_domain_websocket", {});
if cross_domain:contains("*") or cross_domain:contains(true) then
	cross_domain = true;
end

local function check_origin(origin)
	if cross_domain == true then
		return true;
	end
	return cross_domain:contains(origin);
end

local xmlns_framing = "urn:ietf:params:xml:ns:xmpp-framing";
local xmlns_streams = "http://etherx.jabber.org/streams";
local xmlns_client = "jabber:client";
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};

module:depends("c2s")
local sessions = module:shared("c2s/sessions");
local c2s_listener = portmanager.get_service("c2s").listener;

--- Session methods
local function session_open_stream(session)
	local attr = {
		xmlns = xmlns_framing,
		["xml:lang"] = "en",
		version = "1.0",
		id = session.streamid or "",
		from = session.host
	};
	session.send(st.stanza("open", attr));
end

local function session_close(session, reason)
	local log = session.log or log;
	if session.conn then
		if session.notopen then
			session:open_stream();
		end
		if reason then -- nil == no err, initiated by us, false == initiated by client
			local stream_error = st.stanza("stream:error");
			if type(reason) == "string" then -- assume stream error
				stream_error:tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' });
			elseif type(reason) == "table" then
				if reason.condition then
					stream_error:tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stream_error:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stream_error:add_child(reason.extra);
					end
				elseif reason.name then -- a stanza
					stream_error = reason;
				end
			end
			log("debug", "Disconnecting client, <stream:error> is: %s", tostring(stream_error));
			session.send(stream_error);
		end

		session.send(st.stanza("close", { xmlns = xmlns_framing }));
		function session.send() return false; end

		local reason = (reason and (reason.name or reason.text or reason.condition)) or reason;
		session.log("debug", "c2s stream for %s closed: %s", session.full_jid or ("<"..session.ip..">"), reason or "session closed");

		-- Authenticated incoming stream may still be sending us stanzas, so wait for </stream:stream> from remote
		local conn = session.conn;
		if reason == nil and not session.notopen and session.type == "c2s" then
			-- Grace time to process data from authenticated cleanly-closed stream
			add_task(stream_close_timeout, function ()
				if not session.destroyed then
					session.log("warn", "Failed to receive a stream close response, closing connection anyway...");
					sm_destroy_session(session, reason);
					conn:write(build_close(1000, "Stream closed"));
					conn:close();
				end
			end);
		else
			sm_destroy_session(session, reason);
			conn:write(build_close(1000, "Stream closed"));
			conn:close();
		end
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
function handle_request(event)
	local request, response = event.request, event.response;
	local conn = response.conn;

	conn.starttls = false; -- Prevent mod_tls from believing starttls can be done

	if not request.headers.sec_websocket_key then
		response.headers.content_type = "text/html";
		return [[<!DOCTYPE html><html><head><title>Websocket</title></head><body>
			<p>It works! Now point your WebSocket client to this URL to connect to Prosody.</p>
			</body></html>]];
	end

	local wants_xmpp = contains_token(request.headers.sec_websocket_protocol or "", "xmpp");

	if not wants_xmpp then
		module:log("debug", "Client didn't want to talk XMPP, list of protocols was %s", request.headers.sec_websocket_protocol or "(empty)");
		return 501;
	end

	if not check_origin(request.headers.origin or "") then
		module:log("debug", "Origin %s is not allowed by 'cross_domain_websocket'", request.headers.origin or "(missing header)");
		return 403;
	end

	local function websocket_close(code, message)
		conn:write(build_close(code, message));
		conn:close();
	end

	local dataBuffer;
	local function handle_frame(frame)
		local opcode = frame.opcode;
		local length = frame.length;
		module:log("debug", "Websocket received frame: opcode=%0x, %i bytes", frame.opcode, #frame.data);

		-- Error cases
		if frame.RSV1 or frame.RSV2 or frame.RSV3 then -- Reserved bits non zero
			websocket_close(1002, "Reserved bits not zero");
			return false;
		end

		if opcode == 0x8 then -- close frame
			if length == 1 then
				websocket_close(1002, "Close frame with payload, but too short for status code");
				return false;
			elseif length >= 2 then
				local status_code = parse_close(frame.data)
				if status_code < 1000 then
					websocket_close(1002, "Closed with invalid status code");
					return false;
				elseif ((status_code > 1003 and status_code < 1007) or status_code > 1011) and status_code < 3000 then
					websocket_close(1002, "Closed with reserved status code");
					return false;
				end
			end
		end

		if opcode >= 0x8 then
			if length > 125 then -- Control frame with too much payload
				websocket_close(1002, "Payload too large");
				return false;
			end

			if not frame.FIN then -- Fragmented control frame
				websocket_close(1002, "Fragmented control frame");
				return false;
			end
		end

		if (opcode > 0x2 and opcode < 0x8) or (opcode > 0xA) then
			websocket_close(1002, "Reserved opcode");
			return false;
		end

		if opcode == 0x0 and not dataBuffer then
			websocket_close(1002, "Unexpected continuation frame");
			return false;
		end

		if (opcode == 0x1 or opcode == 0x2) and dataBuffer then
			websocket_close(1002, "Continuation frame expected");
			return false;
		end

		-- Valid cases
		if opcode == 0x0 then -- Continuation frame
			dataBuffer[#dataBuffer+1] = frame.data;
		elseif opcode == 0x1 then -- Text frame
			dataBuffer = {frame.data};
		elseif opcode == 0x2 then -- Binary frame
			websocket_close(1003, "Only text frames are supported");
			return;
		elseif opcode == 0x8 then -- Close request
			websocket_close(1000, "Goodbye");
			return;
		elseif opcode == 0x9 then -- Ping frame
			frame.opcode = 0xA;
			conn:write(build_frame(frame));
			return "";
		elseif opcode == 0xA then -- Pong frame, MAY be sent unsolicited, eg as keepalive
			return "";
		else
			log("warn", "Received frame with unsupported opcode %i", opcode);
			return "";
		end

		if frame.FIN then
			local data = t_concat(dataBuffer, "");
			dataBuffer = nil;
			return data;
		end
		return "";
	end

	conn:setlistener(c2s_listener);
	c2s_listener.onconnect(conn);

	local session = sessions[conn];

	session.secure = consider_websocket_secure or session.secure;

	session.open_stream = session_open_stream;
	session.close = session_close;

	local frameBuffer = "";
	add_filter(session, "bytes/in", function(data)
		local cache = {};
		frameBuffer = frameBuffer .. data;
		local frame, length = parse_frame(frameBuffer);

		while frame do
			frameBuffer = frameBuffer:sub(length + 1);
			local result = handle_frame(frame);
			if not result then return; end
			cache[#cache+1] = filter_open_close(result);
			frame, length = parse_frame(frameBuffer);
		end
		return t_concat(cache, "");
	end);

	add_filter(session, "stanzas/out", function(stanza)
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

	session.log("debug", "Sending WebSocket handshake");

	return "";
end

local function keepalive(event)
	local session = event.session;
	if session.open_stream == session_open_stream then
		return session.conn:write(build_frame({ opcode = 0x9, FIN = true }));
	end
end

module:hook("c2s-read-timeout", keepalive, -0.9);

function module.add_host(module)
	module:depends("http");
	module:provides("http", {
		name = "websocket";
		default_path = "xmpp-websocket";
		route = {
			["GET"] = handle_request;
			["GET /"] = handle_request;
		};
	});
	module:hook("c2s-read-timeout", keepalive, -0.9);

	if cross_domain ~= true then
		local url = require "socket.url";
		local ws_url = module:http_url("websocket", "xmpp-websocket");
		local url_components = url.parse(ws_url);
		-- The 'Origin' consists of the base URL without path
		url_components.path = nil;
		local this_origin = url.build(url_components);
		local local_cross_domain = module:get_option_set("cross_domain_websocket", { this_origin });
		-- Don't add / remove something added by another host
		-- This might be weird with random load order
		local_cross_domain:exclude(cross_domain);
		cross_domain:include(local_cross_domain);
		function module.unload()
			cross_domain:exclude(local_cross_domain);
		end
	end
end
