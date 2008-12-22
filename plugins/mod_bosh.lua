
module.host = "*" -- Global module

local lxp = require "lxp";
local init_xmlhandlers = require "core.xmlhandlers"
local server = require "net.server";
local httpserver = require "net.httpserver";
local sm = require "core.sessionmanager";
local new_uuid = require "util.uuid".generate;
local fire_event = require "core.eventmanager".fire_event;
local core_process_stanza = core_process_stanza;
local st = require "util.stanza";
local log = require "util.logger".init("bosh");
local stream_callbacks = { stream_tag = "http://jabber.org/protocol/httpbind|body" };

local xmlns_bosh = "http://jabber.org/protocol/httpbind"; -- (hard-coded into a literal in session.send)

local BOSH_DEFAULT_HOLD = 1;
local BOSH_DEFAULT_INACTIVITY = 30;
local BOSH_DEFAULT_POLLING = 5;
local BOSH_DEFAULT_REQUESTS = 2;
local BOSH_DEFAULT_MAXPAUSE = 120;

local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;
local os_time = os.time;

local sessions = {};

-- Used to respond to idle sessions
local waiting_requests = {};
function on_destroy_request(request)
	waiting_requests[request] = nil;
end

function handle_request(method, body, request)
	if (not body) or request.method ~= "POST" then
		--return { status = "200 OK", headers = { ["Content-Type"] = "text/html" }, body = "<html><body>You don't look like a BOSH client to me... what do you want?</body></html>" };
		return "<html><body>You really don't look like a BOSH client to me... what do you want?</body></html>";
	end
	if not method then 
		log("debug", "Request %s suffered error %s", tostring(request.id), body);
		return;
	end
	log("debug", "Handling new request %s: %s\n----------", request.id, tostring(body));
	request.notopen = true;
	request.log = log;
	local parser = lxp.new(init_xmlhandlers(request, stream_callbacks), "|");
	
	parser:parse(body);
	
	local session = sessions[request.sid];
	if session then
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
				return;
			else
				-- or an empty response
				log("debug", "...sending an empty response");
				session.send("");
				return;
			end
		elseif #session.send_buffer > 0 then
			log("debug", "Session has data in the send buffer, will send now..");
			local resp = t_concat(session.send_buffer);
			session.send_buffer = {};
			session.send(resp);
			return;
		end
		
		if not request.destroyed and session.bosh_wait then
			request.reply_before = os_time() + session.bosh_wait;
			request.on_destroy = on_destroy_request;
			waiting_requests[request] = true;
		end
		
		log("debug", "Had nothing to say, so leaving request unanswered for now");
		return true;
	end
end

local function bosh_reset_stream(session) session.notopen = true; end
local function bosh_close_stream(session, reason) end

function stream_callbacks.streamopened(request, attr)
	print("Attr:")
	for k,v in pairs(attr) do print("", k, v); end
	log("debug", "BOSH body open (sid: %s)", attr.sid);
	local sid = attr.sid
	if not sid then
		-- TODO: Sanity checks here (rid, to, known host, etc.)
		request.notopen = nil; -- Signals that we accept this opening tag
		
		-- New session
		sid = tostring(new_uuid());
		local session = { type = "c2s_unauthed", conn = {}, sid = sid, rid = attr.rid, host = attr.to, bosh_version = attr.ver, bosh_wait = attr.wait, streamid = sid, 
						bosh_hold = BOSH_DEFAULT_HOLD,
						requests = { }, send_buffer = {}, reset_stream = bosh_reset_stream, close = bosh_close_stream };
		sessions[sid] = session;
		log("info", "New BOSH session, assigned it sid '%s'", sid);
		local r, send_buffer = session.requests, session.send_buffer;
		local response = { }
		function session.send(s)
			log("debug", "Sending BOSH data: %s", tostring(s));
			local oldest_request = r[1];
			while oldest_request and oldest_request.destroyed do
				t_remove(r, 1);
				waiting_requests[oldest_request] = nil;
				oldest_request = r[1];
			end
			if oldest_request then
				log("debug", "We have an open request, so using that to send with");
				response.body = t_concat{"<body xmlns='http://jabber.org/protocol/httpbind' sid='", sid, "' xmlns:stream = 'http://etherx.jabber.org/streams'>", tostring(s), "</body>" };
				oldest_request:send(response);
				log("debug", "Sent");
				if oldest_request.stayopen then
					if #r>1 then
						-- Move front request to back
						t_insert(r, oldest_request);
						t_remove(r, 1);
					end
				else
					log("debug", "Destroying the request now...");
					oldest_request:destroy();
					t_remove(r, 1);
				end
			elseif s ~= "" then
				log("debug", "Saved to send buffer because there are %d open requests", #r);
				-- Hmm, no requests are open :(
				t_insert(session.send_buffer, tostring(s));
				log("debug", "There are now %d things in the send_buffer", #session.send_buffer);
			end
		end
		
		-- Send creation response
		
		local features = st.stanza("stream:features");
		fire_event("stream-features", session, features);
		--xmpp:version='1.0' xmlns:xmpp='urn:xmpp:xbosh'
		local response = st.stanza("body", { xmlns = xmlns_bosh, 
									inactivity = "30", polling = "5", requests = "2", hold = tostring(session.bosh_hold), maxpause = "120", 
									sid = sid, ver  = '1.6', from = session.host, secure = 'true', ["xmpp:version"] = "1.0", 
									["xmlns:xmpp"] = "urn:xmpp:xbosh", ["xmlns:stream"] = "http://etherx.jabber.org/streams" }):add_child(features);
		request:send(tostring(response));
				
		request.sid = sid;
		return;
	end
	
	local session = sessions[sid];
	if not session then
		-- Unknown sid
		log("info", "Client tried to use sid '%s' which we don't know about", sid);
		request:send(tostring(st.stanza("body", { xmlns = xmlns_bosh, type = "terminate", condition = "item-not-found" })));
		request.notopen = nil;
		return;
	end
	
	if session.notopen then
		local features = st.stanza("stream:features");
		fire_event("stream-features", session, features);
		session.send(features);
		session.notopen = nil;
	end
	
	request.notopen = nil; -- Signals that we accept this opening tag
	t_insert(session.requests, request);
	request.sid = sid;
end

function stream_callbacks.handlestanza(request, stanza)
	log("debug", "BOSH stanza received: %s\n", stanza:pretty_print());
	local session = sessions[request.sid];
	if session then
		if stanza.attr.xmlns == xmlns_bosh then
			stanza.attr.xmlns = "jabber:client";
		end
		core_process_stanza(session, stanza);
	end
end

function on_timer()
	log("debug", "Checking for requests soon to timeout...");
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
		else
			log("debug", "%s timing out in %ds [destroyed: %s]", request.id, request.reply_before - now, tostring(request.destroyed));
		end
		if not request.on_destroy then
			log("warn", "%s has no on_destroy!", request.id);
		end
	end
end

httpserver.new{ port = 5280, base = "http-bind", handler = handle_request, ssl = false}
server.addtimer(on_timer);