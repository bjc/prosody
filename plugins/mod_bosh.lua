-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global(); -- Global module

local hosts = _G.hosts;
local new_xmpp_stream = require "util.xmppstream".new;
local sm = require "core.sessionmanager";
local sm_destroy_session = sm.destroy_session;
local new_uuid = require "util.uuid".generate;
local fire_event = prosody.events.fire_event;
local core_process_stanza = prosody.core_process_stanza;
local st = require "util.stanza";
local logger = require "util.logger";
local log = logger.init("mod_bosh");
local initialize_filters = require "util.filters".initialize;
local math_min = math.min;

local xmlns_streams = "http://etherx.jabber.org/streams";
local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";
local xmlns_bosh = "http://jabber.org/protocol/httpbind"; -- (hard-coded into a literal in session.send)

local stream_callbacks = {
	stream_ns = xmlns_bosh, stream_tag = "body", default_ns = "jabber:client" };

local BOSH_DEFAULT_HOLD = module:get_option_number("bosh_default_hold", 1);
local BOSH_DEFAULT_INACTIVITY = module:get_option_number("bosh_max_inactivity", 60);
local BOSH_DEFAULT_POLLING = module:get_option_number("bosh_max_polling", 5);
local BOSH_DEFAULT_REQUESTS = module:get_option_number("bosh_max_requests", 2);
local bosh_max_wait = module:get_option_number("bosh_max_wait", 120);

local consider_bosh_secure = module:get_option_boolean("consider_bosh_secure");

local default_headers = { ["Content-Type"] = "text/xml; charset=utf-8", ["Connection"] = "keep-alive" };

local cross_domain = module:get_option("cross_domain_bosh", false);
if cross_domain then
	default_headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS";
	default_headers["Access-Control-Allow-Headers"] = "Content-Type";
	default_headers["Access-Control-Max-Age"] = "7200";

	if cross_domain == true then
		default_headers["Access-Control-Allow-Origin"] = "*";
	elseif type(cross_domain) == "table" then
		cross_domain = table.concat(cross_domain, ", ");
	end
	if type(cross_domain) == "string" then
		default_headers["Access-Control-Allow-Origin"] = cross_domain;
	end
end

local trusted_proxies = module:get_option_set("trusted_proxies", {"127.0.0.1"})._items;

local function get_ip_from_request(request)
	local ip = request.conn:ip();
	local forwarded_for = request.headers.x_forwarded_for;
	if forwarded_for then
		forwarded_for = forwarded_for..", "..ip;
		for forwarded_ip in forwarded_for:gmatch("[^%s,]+") do
			if not trusted_proxies[forwarded_ip] then
				ip = forwarded_ip;
			end
		end
	end
	return ip;
end

local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;
local os_time = os.time;

-- All sessions, and sessions that have no requests open
local sessions, inactive_sessions = module:shared("sessions", "inactive_sessions");

-- Used to respond to idle sessions (those with waiting requests)
local waiting_requests = {};
function on_destroy_request(request)
	log("debug", "Request destroyed: %s", tostring(request));
	waiting_requests[request] = nil;
	local session = sessions[request.context.sid];
	if session then
		local requests = session.requests;
		for i, r in ipairs(requests) do
			if r == request then
				t_remove(requests, i);
				break;
			end
		end
		
		-- If this session now has no requests open, mark it as inactive
		local max_inactive = session.bosh_max_inactive;
		if max_inactive and #requests == 0 then
			inactive_sessions[session] = os_time() + max_inactive;
			(session.log or log)("debug", "BOSH session marked as inactive (for %ds)", max_inactive);
		end
	end
end

function handle_OPTIONS(request)
	local headers = {};
	for k,v in pairs(default_headers) do headers[k] = v; end
	headers["Content-Type"] = nil;
	return { headers = headers, body = "" };
end

function handle_POST(event)
	log("debug", "Handling new request %s: %s\n----------", tostring(event.request), tostring(event.request.body));

	local request, response = event.request, event.response;
	response.on_destroy = on_destroy_request;
	local body = request.body;

	local context = { request = request, response = response, notopen = true };
	local stream = new_xmpp_stream(context, stream_callbacks);
	response.context = context;
	
	-- stream:feed() calls the stream_callbacks, so all stanzas in
	-- the body are processed in this next line before it returns.
	-- In particular, the streamopened() stream callback is where
	-- much of the session logic happens, because it's where we first
	-- get to see the 'sid' of this request.
	stream:feed(body);
	
	-- Stanzas (if any) in the request have now been processed, and
	-- we take care of the high-level BOSH logic here, including
	-- giving a response or putting the request "on hold".
	local session = sessions[context.sid];
	if session then
		-- Session was marked as inactive, since we have
		-- a request open now, unmark it
		if inactive_sessions[session] and #session.requests > 0 then
			inactive_sessions[session] = nil;
		end

		local r = session.requests;
		log("debug", "Session %s has %d out of %d requests open", context.sid, #r, session.bosh_hold);
		log("debug", "and there are %d things in the send_buffer:", #session.send_buffer);
		for i, thing in ipairs(session.send_buffer) do
			log("debug", "    %s", tostring(thing));
		end
		if #r > session.bosh_hold then
			-- We are holding too many requests, send what's in the buffer,
			log("debug", "We are holding too many requests, so...");
			if #session.send_buffer > 0 then
				log("debug", "...sending what is in the buffer")
				session.send(t_concat(session.send_buffer));
				session.send_buffer = {};
			else
				-- or an empty response
				log("debug", "...sending an empty response");
				session.send("");
			end
		elseif #session.send_buffer > 0 then
			log("debug", "Session has data in the send buffer, will send now..");
			local resp = t_concat(session.send_buffer);
			session.send_buffer = {};
			session.send(resp);
		end
		
		if not response.finished then
			-- We're keeping this request open, to respond later
			log("debug", "Have nothing to say, so leaving request unanswered for now");
			if session.bosh_wait then
				waiting_requests[response] = os_time() + session.bosh_wait;
			end
		end
		
		if session.bosh_terminate then
			session.log("debug", "Closing session with %d requests open", #session.requests);
			session:close();
			return nil;
		else
			return true; -- Inform http server we shall reply later
		end
	end
end


local function bosh_reset_stream(session) session.notopen = true; end

local stream_xmlns_attr = { xmlns = "urn:ietf:params:xml:ns:xmpp-streams" };

local function bosh_close_stream(session, reason)
	(session.log or log)("info", "BOSH client disconnected");
	
	local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
		["xmlns:stream"] = xmlns_streams });
	

	if reason then
		close_reply.attr.condition = "remote-stream-error";
		if type(reason) == "string" then -- assume stream error
			close_reply:tag("stream:error")
				:tag(reason, {xmlns = xmlns_xmpp_streams});
		elseif type(reason) == "table" then
			if reason.condition then
				close_reply:tag("stream:error")
					:tag(reason.condition, stream_xmlns_attr):up();
				if reason.text then
					close_reply:tag("text", stream_xmlns_attr):text(reason.text):up();
				end
				if reason.extra then
					close_reply:add_child(reason.extra);
				end
			elseif reason.name then -- a stanza
				close_reply = reason;
			end
		end
		log("info", "Disconnecting client, <stream:error> is: %s", tostring(close_reply));
	end

	local response_body = tostring(close_reply);
	for _, held_request in ipairs(session.requests) do
		held_request.headers = default_headers;
		held_request:send(response_body);
	end
	sessions[session.sid]  = nil;
	inactive_sessions[session] = nil;
	sm_destroy_session(session);
end

-- Handle the <body> tag in the request payload.
function stream_callbacks.streamopened(context, attr)
	local request, response = context.request, context.response;
	local sid = attr.sid;
	log("debug", "BOSH body open (sid: %s)", sid or "<none>");
	if not sid then
		-- New session request
		context.notopen = nil; -- Signals that we accept this opening tag
		
		-- TODO: Sanity checks here (rid, to, known host, etc.)
		if not hosts[attr.to] then
			-- Unknown host
			log("debug", "BOSH client tried to connect to unknown host: %s", tostring(attr.to));
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "host-unknown" });
			response:send(tostring(close_reply));
			return;
		end
		
		-- New session
		sid = new_uuid();
		local session = {
			type = "c2s_unauthed", conn = {}, sid = sid, rid = tonumber(attr.rid)-1, host = attr.to,
			bosh_version = attr.ver, bosh_wait = math_min(attr.wait, bosh_max_wait), streamid = sid,
			bosh_hold = BOSH_DEFAULT_HOLD, bosh_max_inactive = BOSH_DEFAULT_INACTIVITY,
			requests = { }, send_buffer = {}, reset_stream = bosh_reset_stream,
			close = bosh_close_stream, dispatch_stanza = core_process_stanza, notopen = true,
			log = logger.init("bosh"..sid),	secure = consider_bosh_secure or request.secure,
			ip = get_ip_from_request(request);
		};
		sessions[sid] = session;
		
		local filter = initialize_filters(session);
		
		session.log("debug", "BOSH session created for request from %s", session.ip);
		log("info", "New BOSH session, assigned it sid '%s'", sid);

		-- Send creation response
		local creating_session = true;

		local r = session.requests;
		function session.send(s)
			-- We need to ensure that outgoing stanzas have the jabber:client xmlns
			if s.attr and not s.attr.xmlns then
				s = st.clone(s);
				s.attr.xmlns = "jabber:client";
			end
			s = filter("stanzas/out", s);
			--log("debug", "Sending BOSH data: %s", tostring(s));
			t_insert(session.send_buffer, tostring(s));

			local oldest_request = r[1];
			if oldest_request and not session.bosh_processing then
				log("debug", "We have an open request, so sending on that");
				oldest_request.headers = default_headers;
				local body_attr = { xmlns = "http://jabber.org/protocol/httpbind",
					["xmlns:stream"] = "http://etherx.jabber.org/streams";
					type = session.bosh_terminate and "terminate" or nil;
					sid = sid;
				};
				if creating_session then
					creating_session = nil;
					body_attr.inactivity = tostring(BOSH_DEFAULT_INACTIVITY);
					body_attr.polling = tostring(BOSH_DEFAULT_POLLING);
					body_attr.requests = tostring(BOSH_DEFAULT_REQUESTS);
					body_attr.wait = tostring(session.bosh_wait);
					body_attr.hold = tostring(session.bosh_hold);
					body_attr.authid = sid;
					body_attr.secure = "true";
					body_attr.ver  = '1.6';
					body_attr.from = session.host;
					body_attr["xmlns:xmpp"] = "urn:xmpp:xbosh";
					body_attr["xmpp:version"] = "1.0";
				end
				oldest_request:send(st.stanza("body", body_attr):top_tag()..t_concat(session.send_buffer).."</body>");
				session.send_buffer = {};
			end
			return true;
		end
		request.sid = sid;
	end
	
	local session = sessions[sid];
	if not session then
		-- Unknown sid
		log("info", "Client tried to use sid '%s' which we don't know about", sid);
		response.headers = default_headers;
		response:send(tostring(st.stanza("body", { xmlns = xmlns_bosh, type = "terminate", condition = "item-not-found" })));
		context.notopen = nil;
		return;
	end
	
	if session.rid then
		local rid = tonumber(attr.rid);
		local diff = rid - session.rid;
		if diff > 1 then
			session.log("warn", "rid too large (means a request was lost). Last rid: %d New rid: %s", session.rid, attr.rid);
		elseif diff <= 0 then
			-- Repeated, ignore
			session.log("debug", "rid repeated, ignoring: %s (diff %d)", session.rid, diff);
			context.notopen = nil;
			context.ignore = true;
			context.sid = sid;
			t_insert(session.requests, response);
			return;
		end
		session.rid = rid;
	end
	
	if attr.type == "terminate" then
		-- Client wants to end this session, which we'll do
		-- after processing any stanzas in this request
		session.bosh_terminate = true;
	end

	context.notopen = nil; -- Signals that we accept this opening tag
	t_insert(session.requests, response);
	context.sid = sid;
	session.bosh_processing = true; -- Used to suppress replies until processing of this request is done

	if session.notopen then
		local features = st.stanza("stream:features");
		hosts[session.host].events.fire_event("stream-features", { origin = session, features = features });
		fire_event("stream-features", session, features);
		session.send(tostring(features));
		session.notopen = nil;
	end
end

function stream_callbacks.handlestanza(context, stanza)
	if context.ignore then return; end
	log("debug", "BOSH stanza received: %s\n", stanza:top_tag());
	local session = sessions[context.sid];
	if session then
		if stanza.attr.xmlns == xmlns_bosh then
			stanza.attr.xmlns = nil;
		end
		stanza = session.filter("stanzas/in", stanza);
		core_process_stanza(session, stanza);
	end
end

function stream_callbacks.streamclosed(request)
	local session = sessions[request.sid];
	if session then
		session.bosh_processing = false;
		if #session.send_buffer > 0 then
			session.send("");
		end
	end
end

function stream_callbacks.error(context, error)
	log("debug", "Error parsing BOSH request payload; %s", error);
	if not context.sid then
		local response = context.response;
		response.headers = default_headers;
		response.status_code = 400;
		response:send();
		return;
	end
	
	local session = sessions[context.sid];
	if error == "stream-error" then -- Remote stream error, we close normally
		session:close();
	else
		session:close({ condition = "bad-format", text = "Error processing stream" });
	end
end

local dead_sessions = {};
function on_timer()
	-- log("debug", "Checking for requests soon to timeout...");
	-- Identify requests timing out within the next few seconds
	local now = os_time() + 3;
	for request, reply_before in pairs(waiting_requests) do
		if reply_before <= now then
			log("debug", "%s was soon to timeout (at %d, now %d), sending empty response", tostring(request), reply_before, now);
			-- Send empty response to let the
			-- client know we're still here
			if request.conn then
				sessions[request.context.sid].send("");
			end
		end
	end
	
	now = now - 3;
	local n_dead_sessions = 0;
	for session, close_after in pairs(inactive_sessions) do
		if close_after < now then
			(session.log or log)("debug", "BOSH client inactive too long, destroying session at %d", now);
			sessions[session.sid]  = nil;
			inactive_sessions[session] = nil;
			n_dead_sessions = n_dead_sessions + 1;
			dead_sessions[n_dead_sessions] = session;
		end
	end

	for i=1,n_dead_sessions do
		local session = dead_sessions[i];
		dead_sessions[i] = nil;
		sm_destroy_session(session, "BOSH client silent for over "..session.bosh_max_inactive.." seconds");
	end
	return 1;
end
module:add_timer(1, on_timer);


local GET_response = {
	headers = {
		content_type = "text/html";
	};
	body = [[<html><body>
	<p>It works! Now point your BOSH client to this URL to connect to Prosody.</p>
	<p>For more information see <a href="http://prosody.im/doc/setting_up_bosh">Prosody: Setting up BOSH</a>.</p>
	</body></html>]];
};

function module.add_host(module)
	module:depends("http");
	module:provides("http", {
		default_path = "/http-bind";
		route = {
			["GET"] = GET_response;
			["GET /"] = GET_response;
			["OPTIONS"] = handle_OPTIONS;
			["OPTIONS /"] = handle_OPTIONS;
			["POST"] = handle_POST;
			["POST /"] = handle_POST;
		};
	});
end
