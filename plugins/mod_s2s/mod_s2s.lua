-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local prosody = prosody;
local hosts = prosody.hosts;
local core_process_stanza = prosody.core_process_stanza;

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
local fire_global_event = prosody.events.fire_event;

local s2sout = module:require("s2sout");

local connect_timeout = module:get_option_number("s2s_timeout", 90);
local stream_close_timeout = module:get_option_number("s2s_close_timeout", 5);
local opt_keepalives = module:get_option_boolean("s2s_tcp_keepalives", module:get_option_boolean("tcp_keepalives", true));
local secure_auth = module:get_option_boolean("s2s_secure_auth", false); -- One day...
local secure_domains, insecure_domains =
	module:get_option_set("s2s_secure_domains", {})._items, module:get_option_set("s2s_insecure_domains", {})._items;
local require_encryption = module:get_option_boolean("s2s_require_encryption", false);

local measure_connections = module:measure("connections", "counter");

local sessions = module:shared("sessions");

local log = module._log;

--- Handle stanzas to remote domains

local bouncy_stanzas = { message = true, presence = true, iq = true };
local function bounce_sendq(session, reason)
	local sendq = session.sendq;
	if not sendq then return; end
	session.log("info", "Sending error replies for "..#sendq.." queued stanzas because of failed outgoing connection to "..tostring(session.to_host));
	local dummy = {
		type = "s2sin";
		send = function(s)
			(session.log or log)("error", "Replying to to an s2s error reply, please report this! Traceback: %s", traceback());
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

-- Handles stanzas to existing s2s sessions
function route_to_existing_session(event)
	local from_host, to_host, stanza = event.from_host, event.to_host, event.stanza;
	if not hosts[from_host] then
		log("warn", "Attempt to send stanza from %s - a host we don't serve", from_host);
		return false;
	end
	if hosts[to_host] then
		log("warn", "Attempt to route stanza to a remote %s - a host we do serve?!", from_host);
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
			return true;
		elseif host.type == "local" or host.type == "component" then
			log("error", "Trying to send a stanza to ourselves??")
			log("error", "Traceback: %s", traceback());
			log("error", "Stanza: %s", tostring(stanza));
			return false;
		else
			(host.log or log)("debug", "going to send stanza to "..to_host.." from "..from_host);
			-- FIXME
			if host.from_host ~= from_host then
				log("error", "WARNING! This might, possibly, be a bug, but it might not...");
				log("error", "We are going to send from %s instead of %s", tostring(host.from_host), tostring(from_host));
			end
			if host.sends2s(stanza) then
				host.log("debug", "stanza sent over %s", host.type);
				return true;
			end
		end
	end
end

-- Create a new outgoing session for a stanza
function route_to_new_session(event)
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
		s2s_destroy_session(host_session, "Connection failed");
		return false;
	end
	return true;
end

local function keepalive(event)
	return event.session.sends2s(' ');
end

module:hook("s2s-read-timeout", keepalive, -1);

function module.add_host(module)
	if module:get_option_boolean("disallow_s2s", false) then
		module:log("warn", "The 'disallow_s2s' config option is deprecated, please see http://prosody.im/doc/s2s#disabling");
		return nil, "This host has disallow_s2s set";
	end
	module:hook("route/remote", route_to_existing_session, -1);
	module:hook("route/remote", route_to_new_session, -10);
	module:hook("s2s-authenticated", make_authenticated, -1);
	module:hook("s2s-read-timeout", keepalive, -1);
	module:hook_stanza("http://etherx.jabber.org/streams", "features", function (session, stanza)
		if session.type == "s2sout" then
			-- Stream is authenticated and we are seem to be done with feature negotiation,
			-- so the stream is ready for stanzas.  RFC 6120 Section 4.3
			mark_connected(session);
			return true;
		elseif not session.dialback_verifying then
			session.log("warn", "No SASL EXTERNAL offer and Dialback doesn't seem to be enabled, giving up");
			session:close();
			return false;
		end
	end, -1);
end

-- Stream is authorised, and ready for normal stanzas
function mark_connected(session)
	local sendq = session.sendq;

	local from, to = session.from_host, session.to_host;

	session.log("info", "%s s2s connection %s->%s complete", session.direction:gsub("^.", string.upper), from, to);

	local event_data = { session = session };
	if session.type == "s2sout" then
		fire_global_event("s2sout-established", event_data);
		hosts[from].events.fire_event("s2sout-established", event_data);
	else
		local host_session = hosts[to];
		session.send = function(stanza)
			return host_session.events.fire_event("route/remote", { from_host = to, to_host = from, stanza = stanza });
		end;

		fire_global_event("s2sin-established", event_data);
		hosts[to].events.fire_event("s2sin-established", event_data);
	end

	if session.direction == "outgoing" then
		if sendq then
			session.log("debug", "sending %d queued stanzas across new outgoing connection to %s", #sendq, session.to_host);
			local send = session.sends2s;
			for i, data in ipairs(sendq) do
				send(data[1]);
				sendq[i] = nil;
			end
			session.sendq = nil;
		end

		session.ip_hosts = nil;
		session.srv_hosts = nil;
	end
end

function make_authenticated(event)
	local session, host = event.session, event.host;
	if not session.secure then
		if require_encryption or (secure_auth and not(insecure_domains[host])) or secure_domains[host] then
			session:close({
				condition = "policy-violation",
				text = "Encrypted server-to-server communication is required but was not "
				       ..((session.direction == "outgoing" and "offered") or "used")
			});
		end
	end
	if hosts[host] then
		session:close({ condition = "undefined-condition", text = "Attempt to authenticate as a host we serve" });
	end
	if session.type == "s2sout_unauthed" then
		session.type = "s2sout";
	elseif session.type == "s2sin_unauthed" then
		session.type = "s2sin";
		if host then
			if not session.hosts[host] then session.hosts[host] = {}; end
			session.hosts[host].authed = true;
		end
	elseif session.type == "s2sin" and host then
		if not session.hosts[host] then session.hosts[host] = {}; end
		session.hosts[host].authed = true;
	else
		return false;
	end
	session.log("debug", "connection %s->%s is now authenticated for %s", session.from_host, session.to_host, host);

	if (session.type == "s2sout" and session.external_auth ~= "succeeded") or session.type == "s2sin" then
		-- Stream either used dialback for authentication or is an incoming stream.
		mark_connected(session);
	end

	return true;
end

--- Helper to check that a session peer's certificate is valid
function check_cert_status(session)
	local host = session.direction == "outgoing" and session.to_host or session.from_host
	local conn = session.conn:socket()
	local cert
	if conn.getpeercertificate then
		cert = conn:getpeercertificate()
	end

	return module:fire_event("s2s-check-certificate", { host = host, session = session, cert = cert });
end

--- XMPP stream event handlers

local stream_callbacks = { default_ns = "jabber:server", handlestanza =  core_process_stanza };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.streamopened(session, attr)
	session.version = tonumber(attr.version) or 0;

	-- TODO: Rename session.secure to session.encrypted
	if session.secure == false then
		session.secure = true;
		session.encrypted = true;

		local sock = session.conn:socket();
		if sock.info then
			local info = sock:info();
			(session.log or log)("info", "Stream encrypted (%s with %s)", info.protocol, info.cipher);
			session.compressed = info.compression;
		else
			(session.log or log)("info", "Stream encrypted");
			session.compressed = sock.compression and sock:compression(); --COMPAT mw/luasec-hg
		end
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

		-- For convenience we'll put the sanitised values into these variables
		to, from = session.to_host, session.from_host;

		session.streamid = uuid_gen();
		(session.log or log)("debug", "Incoming s2s received %s", st.stanza("stream:stream", attr):top_tag());
		if to then
			if not hosts[to] then
				-- Attempting to connect to a host we don't serve
				session:close({
					condition = "host-unknown";
					text = "This host does not serve "..to
				});
				return;
			elseif not hosts[to].modules.s2s then
				-- Attempting to connect to a host that disallows s2s
				session:close({
					condition = "policy-violation";
					text = "Server-to-server communication is disabled for this host";
				});
				return;
			end
		end

		if hosts[from] then
			session:close({ condition = "undefined-condition", text = "Attempt to connect from a host we serve" });
			return;
		end

		if session.secure and not session.cert_chain_status then
			if check_cert_status(session) == false then
				return;
			end
		end

		session:open_stream(session.to_host, session.from_host)
		session.notopen = nil;
		if session.version >= 1.0 then
			local features = st.stanza("stream:features");

			if to then
				hosts[to].events.fire_event("s2s-stream-features", { origin = session, features = features });
			else
				(session.log or log)("warn", "No 'to' on stream header from %s means we can't offer any features", from or session.ip or "unknown host");
				fire_global_event("s2s-stream-features-legacy", { origin = session, features = features });
			end

			if ( session.type == "s2sin" or session.type == "s2sout" ) or features.tags[1] then
				log("debug", "Sending stream features: %s", tostring(features));
				session.sends2s(features);
			else
				(session.log or log)("warn", "No features to offer, giving up");
				session:close({ condition = "undefined-condition", text = "No features to offer" });
			end
		end
	elseif session.direction == "outgoing" then
		session.notopen = nil;
		if not attr.id then
			log("error", "Stream response did not give us a stream id!");
			session:close({ condition = "undefined-condition", text = "Missing stream ID" });
			return;
		end
		session.streamid = attr.id;

		if session.secure and not session.cert_chain_status then
			if check_cert_status(session) == false then
				return;
			end
		end

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
				hosts[session.from_host].events.fire_event("s2sout-authenticate-legacy", { origin = session });
			else
				mark_connected(session);
			end
		end
	end
end

function stream_callbacks.streamclosed(session)
	(session.log or log)("debug", "Received </stream:stream>");
	session:close(false);
end

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session.log("debug", "Invalid opening stream header (%s)", (data:gsub("^([^\1]+)\1", "{%1}")));
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

local function handleerr(err) log("error", "Traceback[s2s]: %s", traceback(tostring(err), 2)); end
function stream_callbacks.handlestanza(session, stanza)
	if stanza.attr.xmlns == "jabber:client" then --COMPAT: Prosody pre-0.6.2 may send jabber:client
		stanza.attr.xmlns = nil;
	end
	stanza = session.filter("stanzas/in", stanza);
	if stanza then
		return xpcall(function () return core_process_stanza(session, stanza) end, handleerr);
	end
end

local listener = {};

--- Session methods
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local function session_close(session, reason, remote_reason)
	local log = session.log or log;
	if session.conn then
		if session.notopen then
			if session.direction == "incoming" then
				session:open_stream(session.to_host, session.from_host);
			else
				session:open_stream(session.from_host, session.to_host);
			end
		end
		if reason then -- nil == no err, initiated by us, false == initiated by remote
			if type(reason) == "string" then -- assume stream error
				log("debug", "Disconnecting %s[%s], <stream:error> is: %s", session.host or session.ip or "(unknown host)", session.type, reason);
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
					log("debug", "Disconnecting %s[%s], <stream:error> is: %s", session.host or session.ip or "(unknown host)", session.type, tostring(stanza));
					session.sends2s(stanza);
				elseif reason.name then -- a stanza
					log("debug", "Disconnecting %s->%s[%s], <stream:error> is: %s", session.from_host or "(unknown host)", session.to_host or "(unknown host)", session.type, tostring(reason));
					session.sends2s(reason);
				end
			end
		end

		session.sends2s("</stream:stream>");
		function session.sends2s() return false; end

		local reason = remote_reason or (reason and (reason.text or reason.condition)) or reason;
		session.log("info", "%s s2s stream %s->%s closed: %s", session.direction:gsub("^.", string.upper), session.from_host or "(unknown host)", session.to_host or "(unknown host)", reason or "stream closed");

		-- Authenticated incoming stream may still be sending us stanzas, so wait for </stream:stream> from remote
		local conn = session.conn;
		if reason == nil and not session.notopen and session.type == "s2sin" then
			add_task(stream_close_timeout, function ()
				if not session.destroyed then
					session.log("warn", "Failed to receive a stream close response, closing connection anyway...");
					s2s_destroy_session(session, reason);
					conn:close();
				end
			end);
		else
			s2s_destroy_session(session, reason);
			conn:close(); -- Close immediately, as this is an outgoing connection or is not authed
		end
	end
end

function session_stream_attrs(session, from, to, attr)
	if not from or (hosts[from] and hosts[from].modules.dialback) then
		attr["xmlns:db"] = 'jabber:server:dialback';
	end
	if not from then
		attr.from = '';
	end
	if not to then
		attr.to = '';
	end
end

-- Session initialization logic shared by incoming and outgoing
local function initialize_session(session)
	local stream = new_xmpp_stream(session, stream_callbacks);
	local log = session.log or log;
	session.stream = stream;

	session.notopen = true;

	function session.reset_stream()
		session.notopen = true;
		session.streamid = nil;
		session.stream:reset();
	end

	session.stream_attrs = session_stream_attrs;

	local filter = initialize_filters(session);
	local conn = session.conn;
	local w = conn.write;

	function session.sends2s(t)
		log("debug", "sending: %s", t.top_tag and t:top_tag() or t:match("^[^>]*>?"));
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

	function session.data(data)
		data = filter("bytes/in", data);
		if data then
			local ok, err = stream:feed(data);
			if ok then return; end
			log("warn", "Received invalid XML: %s", data);
			log("warn", "Problem was: %s", err);
			session:close("not-well-formed");
		end
	end

	session.close = session_close;

	local handlestanza = stream_callbacks.handlestanza;
	function session.dispatch_stanza(session, stanza)
		return handlestanza(session, stanza);
	end

	module:fire_event("s2s-created", { session = session });

	add_task(connect_timeout, function ()
		if session.type == "s2sin" or session.type == "s2sout" then
			return; -- Ok, we're connected
		elseif session.type == "s2s_destroyed" then
			return; -- Session already destroyed
		end
		-- Not connected, need to close session and clean up
		(session.log or log)("debug", "Destroying incomplete session %s->%s due to inactivity",
		session.from_host or "(unknown)", session.to_host or "(unknown)");
		session:close("connection-timeout");
	end);
end

function listener.onconnect(conn)
	measure_connections(1);
	conn:setoption("keepalive", opt_keepalives);
	local session = sessions[conn];
	if not session then -- New incoming connection
		session = s2s_new_incoming(conn);
		sessions[conn] = session;
		session.log("debug", "Incoming s2s connection");
		initialize_session(session);
	else -- Outgoing session connected
		session:open_stream(session.from_host, session.to_host);
	end
	session.ip = conn:ip();
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
			session.log("debug", "Sending stream header...");
			session:open_stream(session.from_host, session.to_host);
		end
	end
end

function listener.ontimeout(conn)
	-- Called instead of onconnect when the connection times out
	measure_connections(1);
end

function listener.ondisconnect(conn, err)
	measure_connections(-1);
	local session = sessions[conn];
	if session then
		sessions[conn] = nil;
		if err and session.direction == "outgoing" and session.notopen then
			(session.log or log)("debug", "s2s connection attempt failed: %s", err);
			if s2sout.attempt_connection(session, err) then
				return; -- Session lives for now
			end
		end
		(session.log or log)("debug", "s2s disconnected: %s->%s (%s)", tostring(session.from_host), tostring(session.to_host), tostring(err or "connection closed"));
		s2s_destroy_session(session, err);
	end
end

function listener.onreadtimeout(conn)
	local session = sessions[conn];
	local host = session.host or session.to_host;
	if session then
		return (hosts[host] or prosody).events.fire_event("s2s-read-timeout", { session = session });
	end
end

function listener.register_outgoing(conn, session)
	sessions[conn] = session;
	initialize_session(session);
end

function listener.ondetach(conn)
	sessions[conn] = nil;
end

function check_auth_policy(event)
	local host, session = event.host, event.session;
	local must_secure = secure_auth;

	if not must_secure and secure_domains[host] then
		must_secure = true;
	elseif must_secure and insecure_domains[host] then
		must_secure = false;
	end

	if must_secure and (session.cert_chain_status ~= "valid" or session.cert_identity_status ~= "valid") then
		module:log("warn", "Forbidding insecure connection to/from %s", host or session.ip or "(unknown host)");
		if session.direction == "incoming" then
			session:close({ condition = "not-authorized", text = "Your server's certificate is invalid, expired, or not trusted by "..session.to_host });
		else -- Close outgoing connections without warning
			session:close(false);
		end
		return false;
	end
end

module:hook("s2s-check-certificate", check_auth_policy, -1);

s2sout.set_listener(listener);

module:hook("server-stopping", function(event)
	local reason = event.reason;
	for _, session in pairs(sessions) do
		session:close{ condition = "system-shutdown", text = reason };
	end
end, -200);



module:provides("net", {
	name = "s2s";
	listener = listener;
	default_port = 5269;
	encryption = "starttls";
	multiplex = {
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:server%1.*>";
	};
});

