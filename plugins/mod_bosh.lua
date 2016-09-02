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
local core_process_stanza = prosody.core_process_stanza;
local st = require "util.stanza";
local logger = require "util.logger";
local log = logger.init("mod_bosh");
local initialize_filters = require "util.filters".initialize;
local math_min = math.min;
local xpcall, tostring, type = xpcall, tostring, type;
local traceback = debug.traceback;
local nameprep = require "util.encodings".stringprep.nameprep;

local xmlns_streams = "http://etherx.jabber.org/streams";
local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";
local xmlns_bosh = "http://jabber.org/protocol/httpbind"; -- (hard-coded into a literal in session.send)

local stream_callbacks = {
	stream_ns = xmlns_bosh, stream_tag = "body", default_ns = "jabber:client" };

-- These constants are implicitly assumed within the code, and cannot be changed
local BOSH_HOLD = 1;
local BOSH_MAX_REQUESTS = 2;

-- The number of seconds a BOSH session should remain open with no requests
local bosh_max_inactivity = module:get_option_number("bosh_max_inactivity", 60);
-- The minimum amount of time between requests with no payload
local bosh_max_polling = module:get_option_number("bosh_max_polling", 5);
-- The maximum amount of time that the server will hold onto a request before replying
-- (the client can set this to a lower value when it connects, if it chooses)
local bosh_max_wait = module:get_option_number("bosh_max_wait", 120);

local consider_bosh_secure = module:get_option_boolean("consider_bosh_secure");
local cross_domain = module:get_option("cross_domain_bosh", false);

if cross_domain == true then cross_domain = "*"; end
if type(cross_domain) == "table" then cross_domain = table.concat(cross_domain, ", "); end

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
local waiting_requests = module:shared("waiting_requests");
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

local function set_cross_domain_headers(response)
	local headers = response.headers;
	headers.access_control_allow_methods = "GET, POST, OPTIONS";
	headers.access_control_allow_headers = "Content-Type";
	headers.access_control_max_age = "7200";
	headers.access_control_allow_origin = cross_domain;
	return response;
end

function handle_OPTIONS(event)
	if cross_domain and event.request.headers.origin then
		set_cross_domain_headers(event.response);
	end
	return "";
end

function handle_POST(event)
	log("debug", "Handling new request %s: %s\n----------", tostring(event.request), tostring(event.request.body));

	local request, response = event.request, event.response;
	response.on_destroy = on_destroy_request;
	local body = request.body;

	local context = { request = request, response = response, notopen = true };
	local stream = new_xmpp_stream(context, stream_callbacks);
	response.context = context;

	local headers = response.headers;
	headers.content_type = "text/xml; charset=utf-8";

	if cross_domain and event.request.headers.origin then
		set_cross_domain_headers(response);
	end

	-- stream:feed() calls the stream_callbacks, so all stanzas in
	-- the body are processed in this next line before it returns.
	-- In particular, the streamopened() stream callback is where
	-- much of the session logic happens, because it's where we first
	-- get to see the 'sid' of this request.
	local ok, err = stream:feed(body);
	if not ok then
		module:log("warn", "Error parsing BOSH payload; %s", err)
		local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
			["xmlns:stream"] = xmlns_streams, condition = "bad-request" });
		return tostring(close_reply);
	end

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
		log("debug", "Session %s has %d out of %d requests open", context.sid, #r, BOSH_HOLD);
		log("debug", "and there are %d things in the send_buffer:", #session.send_buffer);
		if #r > BOSH_HOLD then
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
	elseif response.finished then
		return; -- A response has been sent already
	end
	module:log("warn", "Unable to associate request with a session (incomplete request?)");
	local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
		["xmlns:stream"] = xmlns_streams, condition = "item-not-found" });
	return tostring(close_reply) .. "\n";
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
		held_request:send(response_body);
	end
	sessions[session.sid] = nil;
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

		local to_host = nameprep(attr.to);
		local rid = tonumber(attr.rid);
		local wait = tonumber(attr.wait);
		if not to_host then
			log("debug", "BOSH client tried to connect to invalid host: %s", tostring(attr.to));
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "improper-addressing" });
			response:send(tostring(close_reply));
			return;
		elseif not hosts[to_host] then
			-- Unknown host
			log("debug", "BOSH client tried to connect to unknown host: %s", tostring(attr.to));
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "host-unknown" });
			response:send(tostring(close_reply));
			return;
		end
		if not rid or (not wait and attr.wait or wait < 0 or wait % 1 ~= 0) then
			log("debug", "BOSH client sent invalid rid or wait attributes: rid=%s, wait=%s", tostring(attr.rid), tostring(attr.wait));
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "bad-request" });
			response:send(tostring(close_reply));
			return;
		end

		rid = rid - 1;
		wait = math_min(wait, bosh_max_wait);

		-- New session
		sid = new_uuid();
		local session = {
			type = "c2s_unauthed", conn = {}, sid = sid, rid = rid, host = attr.to,
			bosh_version = attr.ver, bosh_wait = wait, streamid = sid,
			bosh_max_inactive = bosh_max_inactivity,
			requests = { }, send_buffer = {}, reset_stream = bosh_reset_stream,
			close = bosh_close_stream, dispatch_stanza = core_process_stanza, notopen = true,
			log = logger.init("bosh"..sid),	secure = consider_bosh_secure or request.secure,
			ip = get_ip_from_request(request);
		};
		sessions[sid] = session;

		local filter = initialize_filters(session);

		session.log("debug", "BOSH session created for request from %s", session.ip);
		log("info", "New BOSH session, assigned it sid '%s'", sid);

		hosts[session.host].events.fire_event("bosh-session", { session = session, request = request });

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
			if not s then return true end
			t_insert(session.send_buffer, tostring(s));

			local oldest_request = r[1];
			if oldest_request and not session.bosh_processing then
				log("debug", "We have an open request, so sending on that");
				local body_attr = { xmlns = "http://jabber.org/protocol/httpbind",
					["xmlns:stream"] = "http://etherx.jabber.org/streams";
					type = session.bosh_terminate and "terminate" or nil;
					sid = sid;
				};
				if creating_session then
					creating_session = nil;
					body_attr.requests = tostring(BOSH_MAX_REQUESTS);
					body_attr.hold = tostring(BOSH_HOLD);
					body_attr.inactivity = tostring(bosh_max_inactivity);
					body_attr.polling = tostring(bosh_max_polling);
					body_attr.wait = tostring(session.bosh_wait);
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
		response:send(tostring(st.stanza("body", { xmlns = xmlns_bosh, type = "terminate", condition = "item-not-found" })));
		context.notopen = nil;
		return;
	end

	if session.rid then
		local rid = tonumber(attr.rid);
		local diff = rid - session.rid;
		-- Diff should be 1 for a healthy request
		if diff ~= 1 then
			context.sid = sid;
			context.notopen = nil;
			if diff == 2 then
				-- Hold request, but don't process it (ouch!)
				session.log("debug", "rid skipped: %d, deferring this request", rid-1)
				context.defer = true;
				session.bosh_deferred = { context = context, sid = sid, rid = rid, terminate = attr.type == "terminate" };
				return;
			end
			context.ignore = true;
			if diff == 0 then
				-- Re-send previous response, ignore stanzas in this request
				session.log("debug", "rid repeated, ignoring: %s (diff %d)", session.rid, diff);
				response:send(session.bosh_last_response);
				return;
			end
			-- Session broken, destroy it
			session.log("debug", "rid out of range: %d (diff %d)", rid, diff);
			response:send(tostring(st.stanza("body", { xmlns = xmlns_bosh, type = "terminate", condition = "item-not-found" })));
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
		session.send(features);
		session.notopen = nil;
	end
end

local function handleerr(err) log("error", "Traceback[bosh]: %s", traceback(tostring(err), 2)); end
function stream_callbacks.handlestanza(context, stanza)
	if context.ignore then return; end
	log("debug", "BOSH stanza received: %s\n", stanza:top_tag());
	local session = sessions[context.sid];
	if session then
		if stanza.attr.xmlns == xmlns_bosh then
			stanza.attr.xmlns = nil;
		end
		if context.defer and session.bosh_deferred then
			log("debug", "Deferring this stanza");
			t_insert(session.bosh_deferred, stanza);
		else
			stanza = session.filter("stanzas/in", stanza);
			if stanza then
				return xpcall(function () return core_process_stanza(session, stanza) end, handleerr);
			end
		end
	else
		log("debug", "No session for this stanza! (sid: %s)", context.sid or "none!");
	end
end

function stream_callbacks.streamclosed(context)
	local session = sessions[context.sid];
	if session then
		if not context.defer and session.bosh_deferred then
			-- Handle deferred stanzas now
			local deferred_stanzas = session.bosh_deferred;
			local context = deferred_stanzas.context;
			session.bosh_deferred = nil;
			log("debug", "Handling deferred stanzas from rid %d", deferred_stanzas.rid);
			session.rid = deferred_stanzas.rid;
			t_insert(session.requests, context.response);
			for _, stanza in ipairs(deferred_stanzas) do
				stream_callbacks.handlestanza(context, stanza);
			end
			if deferred_stanzas.terminate then
				session.bosh_terminate = true;
			end
		end
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
		local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
			["xmlns:stream"] = xmlns_streams, condition = "bad-request" });
		response:send(tostring(close_reply));
		return;
	end

	local session = sessions[context.sid];
	if error == "stream-error" then -- Remote stream error, we close normally
		session:close();
	else
		session:close({ condition = "bad-format", text = "Error processing stream" });
	end
end

local dead_sessions = module:shared("dead_sessions");
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
