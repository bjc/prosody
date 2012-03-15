-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local tostring, type = tostring, type;
local t_insert = table.insert;
local xpcall, traceback = xpcall, debug.traceback;

local add_task = require "util.timer".add_task;
local st = require "util.stanza";
local initialize_filters = require "util.filters".initialize;
local nameprep = require "util.encodings".stringprep.nameprep;
local new_xmpp_stream = require "util.xmppstream".new;
local s2s_new_incoming = require "core.s2smanager".new_incoming;
local s2s_new_outgoing = require "core.s2smanager".new_outgoing;
local s2s_destroy_session = require "core.s2smanager".destroy_session;
local uuid_gen = require "util.uuid".generate;
local cert_verify_identity = require "util.x509".verify_identity;

local s2sout = module:require("s2sout");

local connect_timeout = module:get_option_number("s2s_timeout", 60);

local sessions = module:shared("sessions");

--- Handle stanzas to remote domains

local bouncy_stanzas = { message = true, presence = true, iq = true };
local function bounce_sendq(session, reason)
	local sendq = session.sendq;
	if not sendq then return; end
	session.log("info", "sending error replies for "..#sendq.." queued stanzas because of failed outgoing connection to "..tostring(session.to_host));
	local dummy = {
		type = "s2sin";
		send = function(s)
			(session.log or log)("error", "Replying to to an s2s error reply, please report this! Traceback: %s", get_traceback());
		end;
		dummy = true;
	};
	for i, data in ipairs(sendq) do
		local reply = data[2];
		if reply and not(reply.attr.xmlns) and bouncy_stanzas[reply.name] then
			reply.attr.type = "error";
			reply:tag("error", {type = "cancel"})
				:tag("remote-server-not-found", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}):up();
			if reason then
				reply:tag("text", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"})
					:text("Server-to-server connection failed: "..reason):up();
			end
			core_process_stanza(dummy, reply);
		end
		sendq[i] = nil;
	end
	session.sendq = nil;
end

module:hook("route/remote", function (event)
	local from_host, to_host, stanza = event.from_host, event.to_host, event.stanza;
	if not hosts[from_host] then
		log("warn", "Attempt to send stanza from %s - a host we don't serve", from_host);
		return false;
	end
	local host = hosts[from_host].s2sout[to_host];
	if host then
		-- We have a connection to this host already
		if host.type == "s2sout_unauthed" and (stanza.name ~= "db:verify" or not host.dialback_key) then
			(host.log or log)("debug", "trying to send over unauthed s2sout to "..to_host);

			-- Queue stanza until we are able to send it
			if host.sendq then t_insert(host.sendq, {tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza)});
			else host.sendq = { {tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza)} }; end
			host.log("debug", "stanza [%s] queued ", stanza.name);
		elseif host.type == "local" or host.type == "component" then
			log("error", "Trying to send a stanza to ourselves??")
			log("error", "Traceback: %s", get_traceback());
			log("error", "Stanza: %s", tostring(stanza));
			return false;
		else
			(host.log or log)("debug", "going to send stanza to "..to_host.." from "..from_host);
			-- FIXME
			if host.from_host ~= from_host then
				log("error", "WARNING! This might, possibly, be a bug, but it might not...");
				log("error", "We are going to send from %s instead of %s", tostring(host.from_host), tostring(from_host));
			end
			host.sends2s(stanza);
			host.log("debug", "stanza sent over "..host.type);
			return true;
		end
	end
end, 200);

module:hook("route/remote", function (event)
	local from_host, to_host, stanza = event.from_host, event.to_host, event.stanza;
	log("debug", "opening a new outgoing connection for this stanza");
	local host_session = s2s_new_outgoing(from_host, to_host);

	-- Store in buffer
	host_session.bounce_sendq = bounce_sendq;
	host_session.sendq = { {tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza)} };
	log("debug", "stanza [%s] queued until connection complete", tostring(stanza.name));
	s2sout.initiate_connection(host_session);
	if (not host_session.connecting) and (not host_session.conn) then
		log("warn", "Connection to %s failed already, destroying session...", to_host);
		if not s2s_destroy_session(host_session, "Connection failed") then
			-- Already destroyed, we need to bounce our stanza
			host_session:bounce_sendq(host_session.destruction_reason);
		end
		return false;
	end
	return true;
end, 100);

--- Helper to check that a session peer's certificate is valid
local function check_cert_status(session)
	local conn = session.conn:socket()
	local cert
	if conn.getpeercertificate then
		cert = conn:getpeercertificate()
	end

	if cert then
		local chain_valid, errors = conn:getpeerverification()
		-- Is there any interest in printing out all/the number of errors here?
		if not chain_valid then
			(session.log or log)("debug", "certificate chain validation result: invalid");
			session.cert_chain_status = "invalid";
		else
			(session.log or log)("debug", "certificate chain validation result: valid");
			session.cert_chain_status = "valid";

			local host = session.direction == "incoming" and session.from_host or session.to_host

			-- We'll go ahead and verify the asserted identity if the
			-- connecting server specified one.
			if host then
				if cert_verify_identity(host, "xmpp-server", cert) then
					session.cert_identity_status = "valid"
				else
					session.cert_identity_status = "invalid"
				end
			end
		end
	end
end

--- XMPP stream event handlers

local stream_callbacks = { default_ns = "jabber:server", handlestanza =  core_process_stanza };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.streamopened(session, attr)
	local send = session.sends2s;
	
	-- TODO: #29: SASL/TLS on s2s streams
	session.version = tonumber(attr.version) or 0;
	
	-- TODO: Rename session.secure to session.encrypted
	if session.secure == false then
		session.secure = true;
	end

	if session.direction == "incoming" then
		-- Send a reply stream header
		
		-- Validate to/from
		local to, from = nameprep(attr.to), nameprep(attr.from);
		if not to and attr.to then -- COMPAT: Some servers do not reliably set 'to' (especially on stream restarts)
			session:close({ condition = "improper-addressing", text = "Invalid 'to' address" });
			return;
		end
		if not from and attr.from then -- COMPAT: Some servers do not reliably set 'from' (especially on stream restarts)
			session:close({ condition = "improper-addressing", text = "Invalid 'from' address" });
			return;
		end
		
		-- Set session.[from/to]_host if they have not been set already and if
		-- this session isn't already authenticated
		if session.type == "s2sin_unauthed" and from and not session.from_host then
			session.from_host = from;
		elseif from ~= session.from_host then
			session:close({ condition = "improper-addressing", text = "New stream 'from' attribute does not match original" });
			return;
		end
		if session.type == "s2sin_unauthed" and to and not session.to_host then
			session.to_host = to;
		elseif to ~= session.to_host then
			session:close({ condition = "improper-addressing", text = "New stream 'to' attribute does not match original" });
			return;
		end
		
		session.streamid = uuid_gen();
		(session.log or log)("debug", "Incoming s2s received %s", st.stanza("stream:stream", attr):top_tag());
		if session.to_host then
			if not hosts[session.to_host] then
				-- Attempting to connect to a host we don't serve
				session:close({
					condition = "host-unknown";
					text = "This host does not serve "..session.to_host
				});
				return;
			elseif hosts[session.to_host].disallow_s2s then
				-- Attempting to connect to a host that disallows s2s
				session:close({
					condition = "policy-violation";
					text = "Server-to-server communication is not allowed to this host";
				});
				return;
			end
		end

		if session.secure and not session.cert_chain_status then check_cert_status(session); end

		send("<?xml version='1.0'?>");
		send(st.stanza("stream:stream", { xmlns='jabber:server', ["xmlns:db"]='jabber:server:dialback',
				["xmlns:stream"]='http://etherx.jabber.org/streams', id=session.streamid, from=session.to_host, to=session.from_host, version=(session.version > 0 and "1.0" or nil) }):top_tag());
		if session.version >= 1.0 then
			local features = st.stanza("stream:features");
			
			if session.to_host then
				hosts[session.to_host].events.fire_event("s2s-stream-features", { origin = session, features = features });
			else
				(session.log or log)("warn", "No 'to' on stream header from %s means we can't offer any features", session.from_host or "unknown host");
			end
			
			log("debug", "Sending stream features: %s", tostring(features));
			send(features);
		end
	elseif session.direction == "outgoing" then
		-- If we are just using the connection for verifying dialback keys, we won't try and auth it
		if not attr.id then error("stream response did not give us a streamid!!!"); end
		session.streamid = attr.id;

		if session.secure and not session.cert_chain_status then check_cert_status(session); end

		-- Send unauthed buffer
		-- (stanzas which are fine to send before dialback)
		-- Note that this is *not* the stanza queue (which
		-- we can only send if auth succeeds) :)
		local send_buffer = session.send_buffer;
		if send_buffer and #send_buffer > 0 then
			log("debug", "Sending s2s send_buffer now...");
			for i, data in ipairs(send_buffer) do
				session.sends2s(tostring(data));
				send_buffer[i] = nil;
			end
		end
		session.send_buffer = nil;
	
		-- If server is pre-1.0, don't wait for features, just do dialback
		if session.version < 1.0 then
			if not session.dialback_verifying then
				hosts[session.from_host].events.fire_event("s2s-authenticate-legacy", { origin = session });
			else
				s2s_mark_connected(session);
			end
		end
	end
	session.notopen = nil;
	session.send = function(stanza) prosody.events.fire_event("route/remote", { from_host = session.to_host, to_host = session.from_host, stanza = stanza}) end;
end

function stream_callbacks.streamclosed(session)
	(session.log or log)("debug", "Received </stream:stream>");
	session:close();
end

function stream_callbacks.streamdisconnected(session, err)
	if err and err ~= "closed" then
		(session.log or log)("debug", "s2s connection attempt failed: %s", err);
		if s2sout.attempt_connection(session, err) then
			(session.log or log)("debug", "...so we're going to try another target");
			return true; -- Session lives for now
		end
	end
	(session.log or log)("info", "s2s disconnected: %s->%s (%s)", tostring(session.from_host), tostring(session.to_host), tostring(err or "closed"));
	s2s_destroy_session(session, err);
end

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		session.log("debug", "Server-to-server XML parse error: %s", tostring(error));
		session:close("not-well-formed");
	elseif error == "stream-error" then
		local condition, text = "undefined-condition";
		for child in data:children() do
			if child.attr.xmlns == xmlns_xmpp_streams then
				if child.name ~= "text" then
					condition = child.name;
				else
					text = child:get_text();
				end
				if condition ~= "undefined-condition" and text then
					break;
				end
			end
		end
		text = condition .. (text and (" ("..text..")") or "");
		session.log("info", "Session closed by remote with error: %s", text);
		session:close(nil, text);
	end
end

local function handleerr(err) log("error", "Traceback[s2s]: %s: %s", tostring(err), traceback()); end
function stream_callbacks.handlestanza(session, stanza)
	if stanza.attr.xmlns == "jabber:client" then --COMPAT: Prosody pre-0.6.2 may send jabber:client
		stanza.attr.xmlns = nil;
	end
	stanza = session.filter("stanzas/in", stanza);
	if stanza then
		return xpcall(function () return core_process_stanza(session, stanza) end, handleerr);
	end
end

local listener = { default_port = 5269, default_mode = "*a" };

--- Session methods
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = stream_callbacks.default_ns, version = "1.0", id = "" };
local function session_close(session, reason, remote_reason)
	local log = session.log or log;
	if session.conn then
		if session.notopen then
			session.sends2s("<?xml version='1.0'?>");
			session.sends2s(st.stanza("stream:stream", default_stream_attr):top_tag());
		end
		if reason then
			if type(reason) == "string" then -- assume stream error
				log("info", "Disconnecting %s[%s], <stream:error> is: %s", session.host or "(unknown host)", session.type, reason);
				session.sends2s(st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }));
			elseif type(reason) == "table" then
				if reason.condition then
					local stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					log("info", "Disconnecting %s[%s], <stream:error> is: %s", session.host or "(unknown host)", session.type, tostring(stanza));
					session.sends2s(stanza);
				elseif reason.name then -- a stanza
					log("info", "Disconnecting %s->%s[%s], <stream:error> is: %s", session.from_host or "(unknown host)", session.to_host or "(unknown host)", session.type, tostring(reason));
					session.sends2s(reason);
				end
			end
		end
		session.sends2s("</stream:stream>");
		if session.notopen or not session.conn:close() then
			session.conn:close(true); -- Force FIXME: timer?
		end
		session.conn:close();
		listener.ondisconnect(session.conn, remote_reason or (reason and (reason.text or reason.condition)) or reason or "stream closed");
	end
end

-- Session initialization logic shared by incoming and outgoing
local function initialize_session(session)
	local stream = new_xmpp_stream(session, stream_callbacks);
	session.stream = stream;
	
	session.notopen = true;
		
	function session.reset_stream()
		session.notopen = true;
		session.stream:reset();
	end
	
	local filter = session.filter;
	function session.data(data)
		data = filter("bytes/in", data);
		if data then
			local ok, err = stream:feed(data);
			if ok then return; end
			(session.log or log)("warn", "Received invalid XML: %s", data);
			(session.log or log)("warn", "Problem was: %s", err);
			session:close("not-well-formed");
		end
	end

	session.close = session_close;

	local handlestanza = stream_callbacks.handlestanza;
	function session.dispatch_stanza(session, stanza)
		return handlestanza(session, stanza);
	end

	local conn = session.conn;
	add_task(connect_timeout, function ()
		if session.conn ~= conn or session.connecting
		or session.type == "s2sin" or session.type == "s2sout" then
			return; -- Ok, we're connect[ed|ing]
		end
		-- Not connected, need to close session and clean up
		(session.log or log)("debug", "Destroying incomplete session %s->%s due to inactivity",
		session.from_host or "(unknown)", session.to_host or "(unknown)");
		session:close("connection-timeout");
	end);
end

function listener.onconnect(conn)
	if not sessions[conn] then -- May be an existing outgoing session
		local session = s2s_new_incoming(conn);
		sessions[conn] = session;
		session.log("debug", "Incoming s2s connection");

		local filter = initialize_filters(session);
		local w = conn.write;
		session.sends2s = function (t)
			log("debug", "sending: %s", t.top_tag and t:top_tag() or t:match("^([^>]*>?)"));
			if t.name then
				t = filter("stanzas/out", t);
			end
			if t then
				t = filter("bytes/out", tostring(t));
				if t then
					return w(conn, t);
				end
			end
		end
	
		initialize_session(session);
	end
end

function listener.onincoming(conn, data)
	local session = sessions[conn];
	if session then
		session.data(data);
	end
end
	
function listener.onstatus(conn, status)
	if status == "ssl-handshake-complete" then
		local session = sessions[conn];
		if session and session.direction == "outgoing" then
			local to_host, from_host = session.to_host, session.from_host;
			session.log("debug", "Sending stream header...");
			session:open_stream(session.from_host, session.to_host);
		end
	end
end

function listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		if stream_callbacks.streamdisconnected(session, err) then
			return; -- Connection lives, for now
		end
	end
	sessions[conn] = nil;
end

function listener.register_outgoing(conn, session)
	session.direction = "outgoing";
	sessions[conn] = session;
	initialize_session(session);
end

s2sout.set_listener(listener);

module:add_item("net-provider", {
	name = "s2s";
	listener = listener;
	default_port = 5269;
	encryption = "starttls";
	multiplex = {
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:server%1.*>";
	};
});

