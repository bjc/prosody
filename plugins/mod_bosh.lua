-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local new_xmpp_stream = require "prosody.util.xmppstream".new;
local sm = require "prosody.core.sessionmanager";
local sm_destroy_session = sm.destroy_session;
local new_uuid = require "prosody.util.uuid".generate;
local core_process_stanza = prosody.core_process_stanza;
local st = require "prosody.util.stanza";
local logger = require "prosody.util.logger";
local log = module._log;
local initialize_filters = require "prosody.util.filters".initialize;
local math_min = math.min;
local tostring, type = tostring, type;
local traceback = debug.traceback;
local runner = require"prosody.util.async".runner;
local nameprep = require "prosody.util.encodings".stringprep.nameprep;
local cache = require "prosody.util.cache";

local xmlns_streams = "http://etherx.jabber.org/streams";
local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";
local xmlns_bosh = "http://jabber.org/protocol/httpbind"; -- (hard-coded into a literal in session.send)

local stream_callbacks = {
	stream_ns = xmlns_bosh, stream_tag = "body", default_ns = "jabber:client" };

-- These constants are implicitly assumed within the code, and cannot be changed
local BOSH_HOLD = 1;
local BOSH_MAX_REQUESTS = 2;

-- The number of seconds a BOSH session should remain open with no requests
local bosh_max_inactivity = module:get_option_period("bosh_max_inactivity", 60);
-- The minimum amount of time between requests with no payload
local bosh_max_polling = module:get_option_period("bosh_max_polling", 5);
-- The maximum amount of time that the server will hold onto a request before replying
-- (the client can set this to a lower value when it connects, if it chooses)
local bosh_max_wait = module:get_option_period("bosh_max_wait", 120);

local consider_bosh_secure = module:get_option_boolean("consider_bosh_secure");
local cross_domain = module:get_option("cross_domain_bosh");
local stanza_size_limit = module:get_option_integer("c2s_stanza_size_limit", 1024*256, 10000);

if cross_domain ~= nil then
	module:log("info", "The 'cross_domain_bosh' option has been deprecated");
end

local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;

-- All sessions, and sessions that have no requests open
local sessions = module:shared("sessions");

local measure_active = module:measure("active_sessions", "amount");
local measure_inactive = module:measure("inactive_sessions", "amount");
local report_bad_host = module:measure("bad_host", "rate");
local report_bad_sid = module:measure("bad_sid", "rate");
local report_new_sid = module:measure("new_sid", "rate");
local report_timeout = module:measure("timeout", "rate");

module:hook("stats-update", function ()
	local active = 0;
	local inactive = 0;
	for _, session in pairs(sessions) do
		if #session.requests > 0 then
			active = active + 1;
		else
			inactive = inactive + 1;
		end
	end
	measure_active(active);
	measure_inactive(inactive);
end);

-- Used to respond to idle sessions (those with waiting requests)
function on_destroy_request(request)
	log("debug", "Request destroyed: %s", request);
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
			if session.inactive_timer then
				session.inactive_timer:stop();
			end
			session.inactive_timer = module:add_timer(max_inactive, session_timeout, session, request.context,
				"BOSH client silent for over "..max_inactive.." seconds");
			(session.log or log)("debug", "BOSH session marked as inactive (for %ds)", max_inactive);
		end
		if session.bosh_wait_timer then
			session.bosh_wait_timer:stop();
			session.bosh_wait_timer = nil;
		end
	end
end

function session_timeout(now, session, context, reason) -- luacheck: ignore 212/now
	if not session.destroyed then
		report_timeout();
		sessions[context.sid] = nil;
		sm_destroy_session(session, reason);
	end
end

function handle_POST(event)
	log("debug", "Handling new request %s: %s\n----------", event.request, event.request.body);

	local request, response = event.request, event.response;
	response.on_destroy = on_destroy_request;
	local body = request.body;

	local context = { request = request, response = response, notopen = true };
	local stream = new_xmpp_stream(context, stream_callbacks, stanza_size_limit);
	response.context = context;

	local headers = response.headers;
	headers.content_type = "text/xml; charset=utf-8";

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
		if session.inactive_timer and #session.requests > 0 then
			session.inactive_timer:stop();
			session.inactive_timer = nil;
		end

		if session.bosh_wait_timer then
			session.bosh_wait_timer:stop();
			session.bosh_wait_timer = nil;
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
		end

		if session.bosh_terminate then
			session.log("debug", "Closing session with %d requests open", #session.requests);
			session:close();
			return nil;
		else
			if session.bosh_wait and #session.requests > 0 then
				session.bosh_wait_timer = module:add_timer(session.bosh_wait, after_bosh_wait, session.requests[1], session)
			end

			return true; -- Inform http server we shall reply later
		end
	elseif response.finished or context.ignore_request then
		if response.finished then
			module:log("debug", "Response finished");
		end
		if context.ignore_request then
			module:log("debug", "Ignoring this request");
		end
		-- A response has been sent already, or we're ignoring this request
		-- (e.g. so a different instance of the module can handle it)
		return;
	end
	module:log("warn", "Unable to associate request with a session (incomplete request?)");
	report_bad_sid();
	local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
		["xmlns:stream"] = xmlns_streams, condition = "item-not-found" });
	return tostring(close_reply) .. "\n";
end

function after_bosh_wait(now, request, session) -- luacheck: ignore 212
	if request.conn then
		session.send("");
	end
end

local function bosh_reset_stream(session) session.notopen = true; end

local stream_xmlns_attr = { xmlns = "urn:ietf:params:xml:ns:xmpp-streams" };
local function bosh_close_stream(session, reason)
	(session.log or log)("info", "BOSH client disconnected: %s", (reason and reason.condition or reason) or "session close");

	local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
		["xmlns:stream"] = xmlns_streams });


	if reason then
		close_reply.attr.condition = "remote-stream-error";
		if type(reason) == "string" then -- assume stream error
			close_reply:tag("stream:error")
				:tag(reason, {xmlns = xmlns_xmpp_streams});
		elseif st.is_stanza(reason) then
			close_reply = reason;
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
			end
		end
		log("info", "Disconnecting client, <stream:error> is: %s", close_reply);
	end

	local response_body = tostring(close_reply);
	for _, held_request in ipairs(session.requests) do
		held_request:send(response_body);
	end
	sessions[session.sid] = nil;
	sm_destroy_session(session);
end

local runner_callbacks = { };

-- Handle the <body> tag in the request payload.
function stream_callbacks.streamopened(context, attr)
	local request, response = context.request, context.response;
	local sid, rid = attr.sid, tonumber(attr.rid);
	log("debug", "BOSH body open (sid: %s)", sid or "<none>");
	context.rid = rid;
	if not sid then
		-- New session request
		context.notopen = nil; -- Signals that we accept this opening tag

		if not attr.to then
			log("debug", "BOSH client tried to connect without specifying a host");
			report_bad_host();
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "improper-addressing" });
			response:send(tostring(close_reply));
			return;
		end

		local to_host = nameprep(attr.to);
		if not to_host then
			log("debug", "BOSH client tried to connect to invalid host: %s", attr.to);
			report_bad_host();
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "improper-addressing" });
			response:send(tostring(close_reply));
			return;
		end

		if not prosody.hosts[to_host] then
			log("debug", "BOSH client tried to connect to non-existent host: %s", attr.to);
			report_bad_host();
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "improper-addressing" });
			response:send(tostring(close_reply));
			return;
		end

		if prosody.hosts[to_host].type ~= "local" then
			log("debug", "BOSH client tried to connect to %s host: %s", prosody.hosts[to_host].type, attr.to);
			report_bad_host();
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "improper-addressing" });
			response:send(tostring(close_reply));
			return;
		end

		local wait = tonumber(attr.wait);
		if not rid or (not attr.wait or not wait or wait < 0 or wait % 1 ~= 0) then
			log("debug", "BOSH client sent invalid rid or wait attributes: rid=%s, wait=%s", attr.rid, attr.wait);
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:stream"] = xmlns_streams, condition = "bad-request" });
			response:send(tostring(close_reply));
			return;
		end

		wait = math_min(wait, bosh_max_wait);

		-- New session
		sid = new_uuid();
		-- TODO use util.session
		local session = {
			base_type = "c2s", type = "c2s_unauthed", conn = request.conn, sid = sid, host = attr.to,
			rid = rid - 1, -- Hack for initial session setup, "previous" rid was $current_request - 1
			bosh_version = attr.ver, bosh_wait = wait, streamid = sid,
			bosh_max_inactive = bosh_max_inactivity, bosh_responses = cache.new(BOSH_HOLD+1):table();
			requests = { }, send_buffer = {}, reset_stream = bosh_reset_stream,
			close = bosh_close_stream, dispatch_stanza = core_process_stanza, notopen = true,
			log = logger.init("bosh"..sid),	secure = consider_bosh_secure or request.secure,
			ip = request.ip;
		};
		sessions[sid] = session;

		session.thread = runner(function (stanza)
			session:dispatch_stanza(stanza);
		end, runner_callbacks, session);

		local filter = initialize_filters(session);

		session.log("debug", "BOSH session created for request from %s", session.ip);
		log("info", "New BOSH session, assigned it sid '%s'", sid);
		report_new_sid();

		module:fire_event("bosh-session", { session = session, request = request });

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
			--log("debug", "Sending BOSH data: %s", s);
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
				local response_xml = st.stanza("body", body_attr):top_tag()..t_concat(session.send_buffer).."</body>";
				session.bosh_responses[oldest_request.context.rid] = response_xml;
				oldest_request:send(response_xml);
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
		report_bad_sid();
		response:send(tostring(st.stanza("body", { xmlns = xmlns_bosh, type = "terminate", condition = "item-not-found" })));
		context.notopen = nil;
		return;
	end

	session.conn = request.conn;

	if session.rid then
		local diff = rid - session.rid;
		-- Diff should be 1 for a healthy request
		session.log("debug", "rid: %d, sess: %s, diff: %d", rid, session.rid, diff)
		if diff ~= 1 then
			context.sid = sid;
			context.notopen = nil;
			if diff == 2 then -- Missed a request
				-- Hold request, but don't process it (ouch!)
				session.log("debug", "rid skipped: %d, deferring this request", rid-1)
				context.defer = true;
				session.bosh_deferred = { context = context, sid = sid, rid = rid, terminate = attr.type == "terminate" };
				return;
			end
			-- Set a marker to indicate that stanzas in this request should NOT be processed
			-- (these stanzas will already be in the XML parser's buffer)
			context.ignore = true;
			if session.bosh_responses[rid] then
				-- Re-send past response, ignore stanzas in this request
				session.log("debug", "rid repeated within window, replaying old response");
				response:send(session.bosh_responses[rid]);
				return;
			elseif diff == 0 then
				session.log("debug", "current rid repeated, ignoring stanzas");
				t_insert(session.requests, response);
				context.sid = sid;
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
		module:context(session.host):fire_event("stream-features", { origin = session, features = features, stream = attr });
		session.send(features);
		session.notopen = nil;
	end
end

local function handleerr(err) log("error", "Traceback[bosh]: %s", traceback(err, 2)); end

function runner_callbacks:error(err) -- luacheck: ignore 212/self
	return handleerr(err);
end

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
			session.thread:run(stanza);
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
			local deferred_context = deferred_stanzas.context;
			session.bosh_deferred = nil;
			log("debug", "Handling deferred stanzas from rid %d", deferred_stanzas.rid);
			session.rid = deferred_stanzas.rid;
			t_insert(session.requests, deferred_context.response);
			for _, stanza in ipairs(deferred_stanzas) do
				stream_callbacks.handlestanza(deferred_context, stanza);
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
	if not context.sid then
		log("debug", "Error parsing BOSH request payload; %s", error);
		local response = context.response;
		local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
			["xmlns:stream"] = xmlns_streams, condition = "bad-request" });
		response:send(tostring(close_reply));
		return;
	end

	local session = sessions[context.sid];
	(session and session.log or log)("warn", "Error parsing BOSH request payload; %s", error);
	if error == "stream-error" then -- Remote stream error, we close normally
		session:close();
	else
		session:close({ condition = "bad-format", text = "Error processing stream" });
	end
end

local function GET_response(event)
	return module:fire_event("http-message", {
		response = event.response;
		---
		title = "Prosody BOSH endpoint";
		message = "It works! Now point your BOSH client to this URL to connect to Prosody.";
		warning = not (consider_bosh_secure or event.request.secure) and "This endpoint is not considered secure!" or nil;
		-- <p>For more information see <a href="https://prosody.im/doc/setting_up_bosh">Prosody: Setting up BOSH</a>.</p>
	}) or "This is the Prosody BOSH endpoint.";
end

function module.add_host(module)
	module:depends("http");
	module:provides("http", {
		default_path = "/http-bind";
		cors = {
			enabled = true;
		};
		route = {
			["GET"] = GET_response;
			["GET /"] = GET_response;
			["POST"] = handle_POST;
			["POST /"] = handle_POST;
		};
	});

	if module.host ~= "*" then
		module:depends("http_altconnect", true);
	end
end

if require"prosody.core.modulemanager".get_modules_for_host("*"):contains(module.name) then
	module:add_host();
end
