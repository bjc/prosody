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
local traceback = debug.traceback;

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
local runner = require "util.async".runner;
local connect = require "net.connect".connect;
local service = require "net.resolvers.service";
local errors = require "util.error";
local set = require "util.set";

local connect_timeout = module:get_option_number("s2s_timeout", 90);
local stream_close_timeout = module:get_option_number("s2s_close_timeout", 5);
local opt_keepalives = module:get_option_boolean("s2s_tcp_keepalives", module:get_option_boolean("tcp_keepalives", true));
local secure_auth = module:get_option_boolean("s2s_secure_auth", false); -- One day...
local secure_domains, insecure_domains =
	module:get_option_set("s2s_secure_domains", {})._items, module:get_option_set("s2s_insecure_domains", {})._items;
local require_encryption = module:get_option_boolean("s2s_require_encryption", false);

local measure_connections = module:measure("connections", "amount");
local measure_ipv6 = module:measure("ipv6", "amount");

local sessions = module:shared("sessions");

local runner_callbacks = {};

local listener = {};

local log = module._log;

local s2s_service_options = {
	default_port = 5269;
	use_ipv4 = module:get_option_boolean("use_ipv4", true);
	use_ipv6 = module:get_option_boolean("use_ipv6", true);
};

module:hook("stats-update", function ()
	local count = 0;
	local ipv6 = 0;
	for _, session in pairs(sessions) do
		count = count + 1;
		if session.ip and session.ip:match(":") then
			ipv6 = ipv6 + 1;
		end
	end
	measure_connections(count);
	measure_ipv6(ipv6);
end);

--- Handle stanzas to remote domains

local bouncy_stanzas = { message = true, presence = true, iq = true };
local function bounce_sendq(session, reason)
	local sendq = session.sendq;
	if not sendq then return; end
	session.log("info", "Sending error replies for %d queued stanzas because of failed outgoing connection to %s", #sendq, session.to_host);
	local dummy = {
		type = "s2sin";
		send = function ()
			(session.log or log)("error", "Replying to to an s2s error reply, please report this! Traceback: %s", traceback());
		end;
		dummy = true;
		close = function ()
			(session.log or log)("error", "Attempting to close the dummy origin of s2s error replies, please report this! Traceback: %s", traceback());
		end;
	};
	-- FIXME Allow for more specific error conditions
	-- TODO use util.error ?
	local error_type = "cancel";
	local condition = "remote-server-not-found";
	local reason_text;
	if session.had_stream then -- set when a stream is opened by the remote
		error_type, condition = "wait", "remote-server-timeout";
	end
	if errors.is_err(reason) then
		error_type, condition, reason_text = reason.type, reason.condition, reason.text;
	elseif type(reason) == "string" then
		reason_text = reason;
	end
	for i, data in ipairs(sendq) do
		local reply = data[2];
		if reply and not(reply.attr.xmlns) and bouncy_stanzas[reply.name] then
			reply.attr.type = "error";
			reply:tag("error", {type = error_type, by = session.from_host})
				:tag(condition, {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}):up();
			if reason_text then
				reply:tag("text", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"})
					:text("Server-to-server connection failed: "..reason_text):up();
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
	if not host then return end

	-- We have a connection to this host already
	if host.type == "s2sout_unauthed" and (stanza.name ~= "db:verify" or not host.dialback_key) then
		(host.log or log)("debug", "trying to send over unauthed s2sout to "..to_host);

		-- Queue stanza until we are able to send it
		local queued_item = {
			tostring(stanza),
			stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza);
		};
		if host.sendq then
			t_insert(host.sendq, queued_item);
		else
			-- luacheck: ignore 122
			host.sendq = { queued_item };
		end
		host.log("debug", "stanza [%s] queued ", stanza.name);
		return true;
	elseif host.type == "local" or host.type == "component" then
		log("error", "Trying to send a stanza to ourselves??")
		log("error", "Traceback: %s", traceback());
		log("error", "Stanza: %s", stanza);
		return false;
	else
		if host.sends2s(stanza) then
			return true;
		end
	end
end

-- Create a new outgoing session for a stanza
function route_to_new_session(event)
	local from_host, to_host, stanza = event.from_host, event.to_host, event.stanza;
	log("debug", "opening a new outgoing connection for this stanza");
	local host_session = s2s_new_outgoing(from_host, to_host);
	host_session.version = 1;

	-- Store in buffer
	host_session.bounce_sendq = bounce_sendq;
	host_session.sendq = { {tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza)} };
	log("debug", "stanza [%s] queued until connection complete", stanza.name);
	connect(service.new(to_host, "xmpp-server", "tcp", s2s_service_options), listener, nil, { session = host_session });
	return true;
end

local function keepalive(event)
	return event.session.sends2s(' ');
end

module:hook("s2s-read-timeout", keepalive, -1);

function module.add_host(module)
	if module:get_option_boolean("disallow_s2s", false) then
		module:log("warn", "The 'disallow_s2s' config option is deprecated, please see https://prosody.im/doc/s2s#disabling");
		return nil, "This host has disallow_s2s set";
	end
	module:hook("route/remote", route_to_existing_session, -1);
	module:hook("route/remote", route_to_new_session, -10);
	module:hook("s2s-authenticated", make_authenticated, -1);
	module:hook("s2s-read-timeout", keepalive, -1);
	module:hook_stanza("http://etherx.jabber.org/streams", "features", function (session, stanza) -- luacheck: ignore 212/stanza
		if session.type == "s2sout" then
			-- Stream is authenticated and we are seem to be done with feature negotiation,
			-- so the stream is ready for stanzas.  RFC 6120 Section 4.3
			mark_connected(session);
			return true;
		elseif require_encryption and not session.secure then
			session.log("warn", "Encrypted server-to-server communication is required but was not offered by %s", session.to_host);
			session:close({
					condition = "policy-violation",
					text = "Encrypted server-to-server communication is required but was not offered",
				}, nil, "Could not establish encrypted connection to remote server");
			return true;
		elseif not session.dialback_verifying then
			session.log("warn", "No SASL EXTERNAL offer and Dialback doesn't seem to be enabled, giving up");
			session:close({
					condition = "unsupported-feature",
					text = "No viable authentication method offered",
				}, nil, "No viable authentication method offered by remote server");
			return true;
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

		if session.incoming then
			session.send = function(stanza)
				return hosts[from].events.fire_event("route/remote", { from_host = from, to_host = to, stanza = stanza });
			end;
		end

	else
		if session.outgoing and not hosts[to].s2sout[from] then
			session.log("debug", "Setting up to handle route from %s to %s", to, from);
			hosts[to].s2sout[from] = session; -- luacheck: ignore 122
		end
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
			}, nil, "Could not establish encrypted connection to remote server");
		end
	end
	if hosts[host] then
		session:close({ condition = "undefined-condition", text = "Attempt to authenticate as a host we serve" });
	end
	if session.type == "s2sout_unauthed" then
		session.type = "s2sout";
	elseif session.type == "s2sin_unauthed" then
		session.type = "s2sin";
	elseif session.type ~= "s2sin" and session.type ~= "s2sout" then
		return false;
	end

	if session.incoming and host then
		if not session.hosts[host] then session.hosts[host] = {}; end
		session.hosts[host].authed = true;
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

local stream_callbacks = { default_ns = "jabber:server" };

function stream_callbacks.handlestanza(session, stanza)
	stanza = session.filter("stanzas/in", stanza);
	session.thread:run(stanza);
end

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.streamopened(session, attr)
	-- run _streamopened in async context
	session.thread:run({ attr = attr });
end

function stream_callbacks._streamopened(session, attr)
	session.version = tonumber(attr.version) or 0;
	session.had_stream = true; -- Had a stream opened at least once

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
		end
	end

	if session.direction == "incoming" then
		-- Send a reply stream header

		-- Validate to/from
		local to, from = attr.to, attr.from;
		if to then to = nameprep(attr.to); end
		if from then from = nameprep(attr.from); end
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
				log("debug", "Sending stream features: %s", features);
				session.sends2s(features);
			else
				(session.log or log)("warn", "No stream features to offer, giving up");
				session:close({ condition = "undefined-condition", text = "No stream features to offer" });
			end
		end
	elseif session.direction == "outgoing" then
		session.notopen = nil;
		if not attr.id then
			log("warn", "Stream response did not give us a stream id!");
			session:close({ condition = "undefined-condition", text = "Missing stream ID" });
			return;
		end
		session.streamid = attr.id;

		if session.secure and not session.cert_chain_status then
			if check_cert_status(session) == false then
				return;
			end
		end

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
		session.log("debug", "Server-to-server XML parse error: %s", error);
		session:close("not-well-formed");
	elseif error == "stream-error" then
		local condition, text = "undefined-condition";
		for child in data:childtags(nil, xmlns_xmpp_streams) do
			if child.name ~= "text" then
				condition = child.name;
			else
				text = child:get_text();
			end
			if condition ~= "undefined-condition" and text then
				break;
			end
		end
		text = condition .. (text and (" ("..text..")") or "");
		session.log("info", "Session closed by remote with error: %s", text);
		session:close(nil, text);
	end
end

--- Session methods
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local function session_close(session, reason, remote_reason, bounce_reason)
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
			local stream_error;
			if type(reason) == "string" then -- assume stream error
				stream_error = st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' });
			elseif type(reason) == "table" and not st.is_stanza(reason) then
				stream_error = st.stanza("stream:error"):tag(reason.condition or "undefined-condition", stream_xmlns_attr):up();
				if reason.text then
					stream_error:tag("text", stream_xmlns_attr):text(reason.text):up();
				end
				if reason.extra then
					stream_error:add_child(reason.extra);
				end
			end
			if st.is_stanza(stream_error) then
				-- to and from are never unknown on outgoing connections
				log("debug", "Disconnecting %s->%s[%s], <stream:error> is: %s",
					session.from_host or "(unknown host)" or session.ip, session.to_host or "(unknown host)", session.type, reason);
				session.sends2s(stream_error);
			end
		end

		session.sends2s("</stream:stream>");
		function session.sends2s() return false; end

		-- luacheck: ignore 422/reason
		-- FIXME reason should be managed in a place common to c2s, s2s, bosh, component etc
		local reason = remote_reason or (reason and (reason.text or reason.condition)) or reason;
		session.log("info", "%s s2s stream %s->%s closed: %s", session.direction:gsub("^.", string.upper),
			session.from_host or "(unknown host)", session.to_host or "(unknown host)", reason or "stream closed");

		-- Authenticated incoming stream may still be sending us stanzas, so wait for </stream:stream> from remote
		local conn = session.conn;
		if reason == nil and not session.notopen and session.incoming then
			add_task(stream_close_timeout, function ()
				if not session.destroyed then
					session.log("warn", "Failed to receive a stream close response, closing connection anyway...");
					s2s_destroy_session(session, reason, bounce_reason);
					conn:close();
				end
			end);
		else
			s2s_destroy_session(session, reason, bounce_reason);
			conn:close(); -- Close immediately, as this is an outgoing connection or is not authed
		end
	end
end

function session_stream_attrs(session, from, to, attr) -- luacheck: ignore 212/session
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

	session.thread = runner(function (stanza)
		if stanza.name == nil then
			stream_callbacks._streamopened(session, stanza.attr);
		else
			core_process_stanza(session, stanza);
		end
	end, runner_callbacks, session);

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
		log("debug", "Sending[%s]: %s", session.type, t.top_tag and t:top_tag() or t:match("^[^>]*>?"));
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
			log("debug", "Received invalid XML (%s) %d bytes: %q", err, #data, data:sub(1, 300));
			session:close("not-well-formed", nil, "Received invalid XML from remote server");
		end
	end

	session.close = session_close;

	local handlestanza = stream_callbacks.handlestanza;
	function session.dispatch_stanza(session, stanza) -- luacheck: ignore 432/session
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

function runner_callbacks:ready()
	self.data.log("debug", "Runner %s ready (%s)", self.thread, coroutine.status(self.thread));
	self.data.conn:resume();
end

function runner_callbacks:waiting()
	self.data.log("debug", "Runner %s waiting (%s)", self.thread, coroutine.status(self.thread));
	self.data.conn:pause();
end

function runner_callbacks:error(err)
	(self.data.log or log)("error", "Traceback[s2s]: %s", err);
end

function listener.onconnect(conn)
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

function listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		sessions[conn] = nil;
		(session.log or log)("debug", "s2s disconnected: %s->%s (%s)", session.from_host, session.to_host, err or "connection closed");
		if session.secure == false and err then
			-- TODO util.error-ify this
			err = "Error during negotiation of encrypted connection: "..err;
		end
		s2s_destroy_session(session, err);
	end
end

function listener.onfail(data, err)
	local session = data and data.session;
	if session then
		if err and session.direction == "outgoing" and session.notopen then
			(session.log or log)("debug", "s2s connection attempt failed: %s", err);
		end
		(session.log or log)("debug", "s2s disconnected: %s->%s (%s)", session.from_host, session.to_host, err or "connection closed");
		s2s_destroy_session(session, err);
	end
end

function listener.onreadtimeout(conn)
	local session = sessions[conn];
	if session then
		local host = session.host or session.to_host;
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

function listener.onattach(conn, data)
	local session = data and data.session;
	if session then
		session.conn = conn;
		sessions[conn] = session;
		initialize_session(session);
	end
end

-- Complete the sentence "Your certificate " with what's wrong
local function friendly_cert_error(session) --> string
	if session.cert_chain_status == "invalid" then
		if session.cert_chain_errors then
			local cert_errors = set.new(session.cert_chain_errors[1]);
			if cert_errors:contains("certificate has expired") then
				return "has expired";
			elseif cert_errors:contains("self signed certificate") then
				return "is self-signed";
			end
		end
		return "is not trusted"; -- for some other reason
	elseif session.cert_identity_status == "invalid" then
		return "is not valid for this name";
	end
	-- this should normally be unreachable except if no s2s auth module was loaded
	return "could not be validated";
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
		local reason = friendly_cert_error(session);
		session.log("warn", "Forbidding insecure connection to/from %s because its certificate %s", host or session.ip or "(unknown host)", reason);
		-- XEP-0178 recommends closing outgoing connections without warning
		-- but does not give a rationale for this.
		-- In practice most cases are configuration mistakes or forgotten
		-- certificate renewals. We think it's better to let the other party
		-- know about the problem so that they can fix it.
		session:close({ condition = "not-authorized", text = "Your server's certificate "..reason },
			nil, "Remote server's certificate "..reason);
		return false;
	end
end

module:hook("s2s-check-certificate", check_auth_policy, -1);

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
	ssl_config = { -- FIXME This is not used atm, see mod_tls
		verify = { "peer", "client_once", };
	};
	multiplex = {
		protocol = "xmpp-server";
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:server%1.*>";
	};
});

