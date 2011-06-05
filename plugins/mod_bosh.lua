-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module.host = "*" -- Global module

local hosts = _G.hosts;
local lxp = require "lxp";
local new_xmpp_stream = require "util.xmppstream".new;
local httpserver = require "net.httpserver";
local sm = require "core.sessionmanager";
local sm_destroy_session = sm.destroy_session;
local new_uuid = require "util.uuid".generate;
local fire_event = prosody.events.fire_event;
local core_process_stanza = core_process_stanza;
local st = require "util.stanza";
local logger = require "util.logger";
local log = logger.init("mod_bosh");
local timer = require "util.timer";

local xmlns_streams = "http://etherx.jabber.org/streams";
local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";
local xmlns_bosh = "http://jabber.org/protocol/httpbind"; -- (hard-coded into a literal in session.send)

local stream_callbacks = {
	stream_ns = xmlns_bosh, stream_tag = "body", default_ns = "jabber:client" };

local BOSH_DEFAULT_HOLD = tonumber(module:get_option("bosh_default_hold")) or 1;
local BOSH_DEFAULT_INACTIVITY = tonumber(module:get_option("bosh_max_inactivity")) or 60;
local BOSH_DEFAULT_POLLING = tonumber(module:get_option("bosh_max_polling")) or 5;
local BOSH_DEFAULT_REQUESTS = tonumber(module:get_option("bosh_max_requests")) or 2;

local consider_bosh_secure = module:get_option_boolean("consider_bosh_secure");

local default_headers = { ["Content-Type"] = "text/xml; charset=utf-8" };

local cross_domain = module:get_option("cross_domain_bosh");
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
	local ip = request.handler:ip();
	local forwarded_for = request.headers["x-forwarded-for"];
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

local sessions = {};
local inactive_sessions = {}; -- Sessions which have no open requests

-- Used to respond to idle sessions (those with waiting requests)
local waiting_requests = {};
function on_destroy_request(request)
	waiting_requests[request] = nil;
	local session = sessions[request.sid];
	if session then
		local requests = session.requests;
		for i,r in ipairs(requests) do
			if r == request then
				t_remove(requests, i);
				break;
			end
		end
		
		-- If this session now has no requests open, mark it as inactive
		if #requests == 0 and session.bosh_max_inactive and not inactive_sessions[session] then
			inactive_sessions[session] = os_time();
			(session.log or log)("debug", "BOSH session marked as inactive at %d", inactive_sessions[session]);
		end
	end
end

function handle_request(method, body, request)
	if (not body) or request.method ~= "POST" then
		if request.method == "OPTIONS" then
			local headers = {};
			for k,v in pairs(default_headers) do headers[k] = v; end
			headers["Content-Type"] = nil;
			return { headers = headers, body = "" };
		else
			return "<html><body>You really don't look like a BOSH client to me... what do you want?</body></html>";
		end
	end
	if not method then
		log("debug", "Request %s suffered error %s", tostring(request.id), body);
		return;
	end
	--log("debug", "Handling new request %s: %s\n----------", request.id, tostring(body));
	request.notopen = true;
	request.log = log;
	request.on_destroy = on_destroy_request;
	
	local stream = new_xmpp_stream(request, stream_callbacks);
	-- stream:feed() calls the stream_callbacks, so all stanzas in
	-- the body are processed in this next line before it returns.
	stream:feed(body);
	
	local session = sessions[request.sid];
	if session then
		-- Session was marked as inactive, since we have
		-- a request open now, unmark it
		if inactive_sessions[session] and #session.requests > 0 then
			inactive_sessions[session] = nil;
		end

		local r = session.requests;
		log("debug", "Session %s has %d out of %d requests open", request.sid, #r, session.bosh_hold);
		log("debug", "and there are %d things in the send_buffer", #session.send_buffer);
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
		
		if not request.destroyed then
			-- We're keeping this request open, to respond later
			log("debug", "Have nothing to say, so leaving request unanswered for now");
			if session.bosh_wait then
				request.reply_before = os_time() + session.bosh_wait;
				waiting_requests[request] = true;
			end
		end
		
		return true; -- Inform httpserver we shall reply later
	end
end


local function bosh_reset_stream(session) session.notopen = true; end

local stream_xmlns_attr = { xmlns = "urn:ietf:params:xml:ns:xmpp-streams" };

local function bosh_close_stream(session, reason)
	(session.log or log)("info", "BOSH client disconnected");
	
	local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
		["xmlns:streams"] = xmlns_streams });
	

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

	local session_close_response = { headers = default_headers, body = tostring(close_reply) };

	--FIXME: Quite sure we shouldn't reply to all requests with the error
	for _, held_request in ipairs(session.requests) do
		held_request:send(session_close_response);
		held_request:destroy();
	end
	sessions[session.sid]  = nil;
	sm_destroy_session(session);
end

function stream_callbacks.streamopened(request, attr)
	log("debug", "BOSH body open (sid: %s)", attr.sid);
	local sid = attr.sid
	if not sid then
		-- New session request
		request.notopen = nil; -- Signals that we accept this opening tag
		
		-- TODO: Sanity checks here (rid, to, known host, etc.)
		if not hosts[attr.to] then
			-- Unknown host
			log("debug", "BOSH client tried to connect to unknown host: %s", tostring(attr.to));
			local close_reply = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate",
				["xmlns:streams"] = xmlns_streams, condition = "host-unknown" });
			request:send(tostring(close_reply));
			return;
		end
		
		-- New session
		sid = new_uuid();
		local session = {
			type = "c2s_unauthed", conn = {}, sid = sid, rid = tonumber(attr.rid), host = attr.to,
			bosh_version = attr.ver, bosh_wait = attr.wait, streamid = sid,
			bosh_hold = BOSH_DEFAULT_HOLD, bosh_max_inactive = BOSH_DEFAULT_INACTIVITY,
			requests = { }, send_buffer = {}, reset_stream = bosh_reset_stream,
			close = bosh_close_stream, dispatch_stanza = core_process_stanza,
			log = logger.init("bosh"..sid),	secure = consider_bosh_secure or request.secure,
			ip = get_ip_from_request(request);
		};
		sessions[sid] = session;
		
		session.log("debug", "BOSH session created for request from %s", session.ip);
		log("info", "New BOSH session, assigned it sid '%s'", sid);
		local r, send_buffer = session.requests, session.send_buffer;
		local response = { headers = default_headers }
		function session.send(s)
			-- We need to ensure that outgoing stanzas have the jabber:client xmlns
			if s.attr and not s.attr.xmlns then
				s = st.clone(s);
				s.attr.xmlns = "jabber:client";
			end
			--log("debug", "Sending BOSH data: %s", tostring(s));
			local oldest_request = r[1];
			if oldest_request then
				log("debug", "We have an open request, so sending on that");
				response.body = t_concat{"<body xmlns='http://jabber.org/protocol/httpbind' sid='", sid, "' xmlns:stream = 'http://etherx.jabber.org/streams'>", tostring(s), "</body>" };
				oldest_request:send(response);
				--log("debug", "Sent");
				if oldest_request.stayopen then
					if #r>1 then
						-- Move front request to back
						t_insert(r, oldest_request);
						t_remove(r, 1);
					end
				else
					log("debug", "Destroying the request now...");
					oldest_request:destroy();
				end
			elseif s ~= "" then
				log("debug", "Saved to send buffer because there are %d open requests", #r);
				-- Hmm, no requests are open :(
				t_insert(session.send_buffer, tostring(s));
				log("debug", "There are now %d things in the send_buffer", #session.send_buffer);
			end
			return true;
		end
		
		-- Send creation response
		
		local features = st.stanza("stream:features");
		hosts[session.host].events.fire_event("stream-features", { origin = session, features = features });
		fire_event("stream-features", session, features);
		--xmpp:version='1.0' xmlns:xmpp='urn:xmpp:xbosh'
		local response = st.stanza("body", { xmlns = xmlns_bosh,
			wait = attr.wait,
			inactivity = tostring(BOSH_DEFAULT_INACTIVITY),
			polling = tostring(BOSH_DEFAULT_POLLING),
			requests = tostring(BOSH_DEFAULT_REQUESTS),
			hold = tostring(session.bosh_hold),
			sid = sid, authid = sid,
			ver  = '1.6', from = session.host,
			secure = 'true', ["xmpp:version"] = "1.0",
			["xmlns:xmpp"] = "urn:xmpp:xbosh",
			["xmlns:stream"] = "http://etherx.jabber.org/streams"
		}):add_child(features);
		request:send{ headers = default_headers, body = tostring(response) };
		
		request.sid = sid;
		return;
	end
	
	local session = sessions[sid];
	if not session then
		-- Unknown sid
		log("info", "Client tried to use sid '%s' which we don't know about", sid);
		request:send{ headers = default_headers, body = tostring(st.stanza("body", { xmlns = xmlns_bosh, type = "terminate", condition = "item-not-found" })) };
		request.notopen = nil;
		return;
	end
	
	if session.rid then
		local rid = tonumber(attr.rid);
		local diff = rid - session.rid;
		if diff > 1 then
			session.log("warn", "rid too large (means a request was lost). Last rid: %d New rid: %s", session.rid, attr.rid);
		elseif diff <= 0 then
			-- Repeated, ignore
			session.log("debug", "rid repeated (on request %s), ignoring: %s (diff %d)", request.id, session.rid, diff);
			request.notopen = nil;
			request.ignore = true;
			request.sid = sid;
			t_insert(session.requests, request);
			return;
		end
		session.rid = rid;
	end
	
	if attr.type == "terminate" then
		-- Client wants to end this session
		session:close();
		request.notopen = nil;
		return;
	end
	
	if session.notopen then
		local features = st.stanza("stream:features");
		hosts[session.host].events.fire_event("stream-features", { origin = session, features = features });
		fire_event("stream-features", session, features);
		session.send(features);
		session.notopen = nil;
	end
	
	request.notopen = nil; -- Signals that we accept this opening tag
	t_insert(session.requests, request);
	request.sid = sid;
end

function stream_callbacks.handlestanza(request, stanza)
	if request.ignore then return; end
	log("debug", "BOSH stanza received: %s\n", stanza:top_tag());
	local session = sessions[request.sid];
	if session then
		if stanza.attr.xmlns == xmlns_bosh then
			stanza.attr.xmlns = nil;
		end
		core_process_stanza(session, stanza);
	end
end

function stream_callbacks.error(request, error)
	log("debug", "Error parsing BOSH request payload; %s", error);
	if not request.sid then
		request:send({ headers = default_headers, status = "400 Bad Request" });
		return;
	end
	
	local session = sessions[request.sid];
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
	for request in pairs(waiting_requests) do
		if request.reply_before <= now then
			log("debug", "%s was soon to timeout, sending empty response", request.id);
			-- Send empty response to let the
			-- client know we're still here
			if request.conn then
				sessions[request.sid].send("");
			end
		end
	end
	
	now = now - 3;
	local n_dead_sessions = 0;
	for session, inactive_since in pairs(inactive_sessions) do
		if session.bosh_max_inactive then
			if now - inactive_since > session.bosh_max_inactive then
				(session.log or log)("debug", "BOSH client inactive too long, destroying session at %d", now);
				sessions[session.sid]  = nil;
				inactive_sessions[session] = nil;
				n_dead_sessions = n_dead_sessions + 1;
				dead_sessions[n_dead_sessions] = session;
			end
		else
			inactive_sessions[session] = nil;
		end
	end

	for i=1,n_dead_sessions do
		local session = dead_sessions[i];
		dead_sessions[i] = nil;
		sm_destroy_session(session, "BOSH client silent for over "..session.bosh_max_inactive.." seconds");
	end
	return 1;
end


local function setup()
	local ports = module:get_option("bosh_ports") or { 5280 };
	httpserver.new_from_config(ports, handle_request, { base = "http-bind" });
	timer.add_task(1, on_timer);
end
if prosody.start_time then -- already started
	setup();
else
	prosody.events.add_handler("server-started", setup);
end
