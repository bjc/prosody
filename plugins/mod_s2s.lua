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
local traceback = debug.traceback;

local add_task = require "prosody.util.timer".add_task;
local stop_timer = require "prosody.util.timer".stop;
local st = require "prosody.util.stanza";
local initialize_filters = require "prosody.util.filters".initialize;
local nameprep = require "prosody.util.encodings".stringprep.nameprep;
local new_xmpp_stream = require "prosody.util.xmppstream".new;
local s2s_new_incoming = require "prosody.core.s2smanager".new_incoming;
local s2s_new_outgoing = require "prosody.core.s2smanager".new_outgoing;
local s2s_destroy_session = require "prosody.core.s2smanager".destroy_session;
local uuid_gen = require "prosody.util.uuid".generate;
local async = require "prosody.util.async";
local runner = async.runner;
local connect = require "prosody.net.connect".connect;
local service = require "prosody.net.resolvers.service";
local resolver_chain = require "prosody.net.resolvers.chain";
local errors = require "prosody.util.error";
local set = require "prosody.util.set";
local queue = require "prosody.util.queue";

local connect_timeout = module:get_option_period("s2s_timeout", 90);
local stream_close_timeout = module:get_option_period("s2s_close_timeout", 5);
local opt_keepalives = module:get_option_boolean("s2s_tcp_keepalives", module:get_option_boolean("tcp_keepalives", true));
local secure_auth = module:get_option_boolean("s2s_secure_auth", false); -- One day...
local secure_domains, insecure_domains =
	module:get_option_set("s2s_secure_domains", {})._items, module:get_option_set("s2s_insecure_domains", {})._items;
local require_encryption = module:get_option_boolean("s2s_require_encryption", true);
local stanza_size_limit = module:get_option_integer("s2s_stanza_size_limit", 1024*512, 10000);
local sendq_size = module:get_option_integer("s2s_send_queue_size", 1024*32, 1);

local advertised_idle_timeout = 14*60; -- default in all net.server implementations
local network_settings = module:get_option("network_settings");
if type(network_settings) == "table" and type(network_settings.read_timeout) == "number" then
	advertised_idle_timeout = network_settings.read_timeout;
end

local measure_connections_inbound = module:metric(
	"gauge", "connections_inbound", "",
	"Established incoming s2s connections",
	{"host", "type", "ip_family"}
);
local measure_connections_outbound = module:metric(
	"gauge", "connections_outbound", "",
	"Established outgoing s2s connections",
	{"host", "type", "ip_family"}
);

local m_accepted_tcp_connections = module:metric(
	"counter", "accepted_tcp", "",
	"Accepted incoming connections on the TCP layer"
);
local m_authn_connections = module:metric(
	"counter", "authenticated", "",
	"Authenticated incoming connections",
	{"host", "direction", "mechanism"}
);
local m_initiated_connections = module:metric(
	"counter", "initiated", "",
	"Initiated outbound connections",
	{"host"}
);
local m_closed_connections = module:metric(
	"counter", "closed", "",
	"Closed connections",
	{"host", "direction", "error"}
);
local m_tls_params = module:metric(
	"counter", "encrypted", "",
	"Encrypted connections",
	{"protocol"; "cipher"}
);

local sessions = module:shared("sessions");

local runner_callbacks = {};
local session_events = {};

local listener = {};

local log = module._log;

local s2s_service_options = {
	default_port = 5269;
	use_ipv4 = module:get_option_boolean("use_ipv4", true);
	use_ipv6 = module:get_option_boolean("use_ipv6", true);
	use_dane = module:get_option_boolean("use_dane", false);
};
local s2s_service_options_mt = { __index = s2s_service_options }

if module:get_option_boolean("use_dane", false) then
	-- DANE is supported in net.connect but only for outgoing connections,
	-- to authenticate incoming connections with DANE we need
	module:depends("s2s_auth_dane_in");
end

module:hook("stats-update", function ()
	measure_connections_inbound:clear()
	measure_connections_outbound:clear()
	-- TODO: init all expected metrics once?
	-- or maybe create/delete them in host-activate/host-deactivate? requires
	-- extra API in openmetrics.lua tho
	for _, session in pairs(sessions) do
		local is_inbound = string.sub(session.type, 4, 5) == "in"
		local metric_family = is_inbound and measure_connections_inbound or measure_connections_outbound
		local host = is_inbound and session.to_host or session.from_host or ""
		local type_ = session.type or "other"

		-- we want to expose both v4 and v6 counters in all cases to make
		-- queries smoother
		local is_ipv6 = session.ip and session.ip:match(":") and 1 or 0
		local is_ipv4 = 1 - is_ipv6
		metric_family:with_labels(host, type_, "ipv4"):add(is_ipv4)
		metric_family:with_labels(host, type_, "ipv6"):add(is_ipv6)
	end
end);

--- Handle stanzas to remote domains

local bouncy_stanzas = { message = true, presence = true, iq = true };
local function bounce_sendq(session, reason)
	local sendq = session.sendq;
	if not sendq then return; end
	session.log("info", "Sending error replies for %d queued stanzas because of failed outgoing connection to %s", sendq.count(), session.to_host);
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
	if errors.is_error(reason) then
		error_type, condition, reason_text = reason.type, reason.condition, reason.text;
	elseif type(reason) == "string" then
		reason_text = reason;
	end
	for stanza in sendq:consume() do
		if not stanza.attr.xmlns and bouncy_stanzas[stanza.name] and stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
			local reply = st.error_reply(
				stanza,
				error_type,
				condition,
				reason_text and ("Server-to-server connection failed: "..reason_text) or nil
			);
			core_process_stanza(dummy, reply);
		else
			(session.log or log)("debug", "Not eligible for bouncing, discarding %s", stanza:top_tag());
		end
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
		if not host.sendq then
			-- luacheck: ignore 122
			host.sendq = queue.new(sendq_size);
		end
		if not host.sendq:push(st.clone(stanza)) then
			host.log("warn", "stanza [%s] not queued ", stanza.name);
			event.origin.send(st.error_reply(stanza, "wait", "resource-constraint", "Outgoing stanza queue full"));
			return true;
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
	host_session.sendq = queue.new(sendq_size);
	host_session.sendq:push(st.clone(stanza));
	log("debug", "stanza [%s] queued until connection complete", stanza.name);
	-- FIXME Cleaner solution to passing extra data from resolvers to net.server
	-- This mt-clone allows resolvers to add extra data, currently used for DANE TLSA records
	module:context(from_host):fire_event("s2sout-created", { session = host_session });
	local xmpp_extra = setmetatable({}, s2s_service_options_mt);
	local resolver = service.new(to_host, "xmpp-server", "tcp", xmpp_extra);
	if host_session.ssl_ctx then
		local sslctx = host_session.ssl_ctx;
		local xmpps_extra = setmetatable({ default_port = false; servername = to_host; sslctx = sslctx }, s2s_service_options_mt);
		resolver = resolver_chain.new({
			service.new(to_host, "xmpps-server", "tcp", xmpps_extra);
			resolver;
		});
	end

	local pre_event = { session = host_session; resolver = resolver };
	module:context(from_host):fire_event("s2sout-pre-connect", pre_event);
	resolver = pre_event.resolver;
	connect(resolver, listener, nil, { session = host_session });
	m_initiated_connections:with_labels(from_host):add(1)
	return true;
end

local function keepalive(event)
	local session = event.session;
	if not session.notopen then
		return event.session.sends2s(' ');
	end
end

module:hook("s2s-read-timeout", keepalive, -1);

function module.add_host(module)
	if module:get_option_boolean("disallow_s2s", false) then
		module:log("warn", "The 'disallow_s2s' config option is deprecated, please see https://prosody.im/doc/s2s#disabling");
		return nil, "This host has disallow_s2s set";
	end
	module:hook("route/remote", route_to_existing_session, -1);
	module:hook("route/remote", route_to_new_session, -10);
	module:hook("s2sout-stream-features", function (event)
		if not (stanza_size_limit or advertised_idle_timeout) then return end
		local limits = event.features:tag("limits", { xmlns = "urn:xmpp:stream-limits:0" })
		if stanza_size_limit then
			limits:text_tag("max-bytes", string.format("%d", stanza_size_limit));
		end
		if advertised_idle_timeout then
			limits:text_tag("idle-seconds", string.format("%d", advertised_idle_timeout));
		end
		limits:up();
	end);
	module:hook_tag("urn:xmpp:bidi", "bidi", function(session, stanza)
		-- Advertising features on bidi connections where no <stream:features> is sent in the other direction
		local limits = stanza:get_child("limits", "urn:xmpp:stream-limits:0");
		if limits then
			session.outgoing_stanza_size_limit = tonumber(limits:get_child_text("max-bytes"));
		end
	end, 100);
	module:hook("s2s-authenticated", make_authenticated, -1);
	module:hook("s2s-read-timeout", keepalive, -1);
	module:hook("smacks-ack-delayed", function (event)
		if event.origin.type == "s2sin" or event.origin.type == "s2sout" then
			event.origin:close("connection-timeout");
			return true;
		end
	end, -1);
	module:hook_stanza("http://etherx.jabber.org/streams", "features", function (session, stanza) -- luacheck: ignore 212/stanza
		local limits = stanza:get_child("limits", "urn:xmpp:stream-limits:0");
		if limits then
			session.outgoing_stanza_size_limit = tonumber(limits:get_child_text("max-bytes"));
		end
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

	function module.unload()
		if module.reloading then return end
		for _, session in pairs(sessions) do
			if session.host == module.host then
				session:close("host-gone");
			end
		end
	end
end

-- Stream is authorised, and ready for normal stanzas
function mark_connected(session)

	local sendq = session.sendq;

	local from, to = session.from_host, session.to_host;

	session.log("info", "%s s2s connection %s->%s complete", session.direction:gsub("^.", string.upper), from, to);

	local event_data = { session = session };
	if session.type == "s2sout" then
		module:fire_event("s2sout-established", event_data);
		module:context(from):fire_event("s2sout-established", event_data);

		if session.incoming then
			session.send = function(stanza)
				return module:context(from):fire_event("route/remote", { from_host = from, to_host = to, stanza = stanza });
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

		module:fire_event("s2sin-established", event_data);
		module:context(to):fire_event("s2sin-established", event_data);
	end

	if session.direction == "outgoing" then
		if sendq then
			session.log("debug", "sending %d queued stanzas across new outgoing connection to %s", sendq.count(), session.to_host);
			local send = session.sends2s;
			for stanza in sendq:consume() do
				-- TODO check send success
				send(stanza);
			end
			session.sendq = nil;
		end
	end

	if session.connect_timeout then
		stop_timer(session.connect_timeout);
		session.connect_timeout = nil;
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

	if session.type == "s2sout_unauthed" and not session.authenticated_remote and secure_auth and not insecure_domains[host] then
		session:close({
			condition = "policy-violation";
			text = "Failed to verify certificate (internal error)";
		});
		return;
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

	local local_host = session.direction == "incoming" and session.to_host or session.from_host
	m_authn_connections:with_labels(local_host, session.direction, event.mechanism or "other"):add(1)

	if (session.type == "s2sout" and session.external_auth ~= "succeeded") or session.type == "s2sin" then
		-- Stream either used dialback for authentication or is an incoming stream.
		mark_connected(session);
	end

	return true;
end

--- Helper to check that a session peer's certificate is valid
local function check_cert_status(session)
	local host = session.direction == "outgoing" and session.to_host or session.from_host
	local conn = session.conn
	local cert
	if conn.ssl_peercertificate then
		cert = conn:ssl_peercertificate()
	end

	return module:fire_event("s2s-check-certificate", { host = host, session = session, cert = cert });
end

--- XMPP stream event handlers

local function session_secure(session)
	session.secure = true;
	session.encrypted = true;

	local info = session.conn:ssl_info();
	if type(info) == "table" then
		(session.log or log)("info", "Stream encrypted (%s with %s)", info.protocol, info.cipher);
		session.compressed = info.compression;
		m_tls_params:with_labels(info.protocol, info.cipher):add(1)
	else
		(session.log or log)("info", "Stream encrypted");
	end
end

local stream_callbacks = { default_ns = "jabber:server" };

function stream_callbacks.handlestanza(session, stanza)
	stanza = session.filter("stanzas/in", stanza);
	session.thread:run(stanza);
end

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.streamopened(session, attr)
	-- run _streamopened in async context
	session.thread:run({ event = "streamopened", attr = attr });
end

function session_events.streamopened(session, event)
	local attr = event.attr;
	session.version = tonumber(attr.version) or 0;
	session.had_stream = true; -- Had a stream opened at least once

	-- TODO: Rename session.secure to session.encrypted
	if session.secure == false then -- Set by mod_tls during STARTTLS handshake
		session.starttls = "completed";
		session_secure(session);
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
			session.host = to;
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
		if session.destroyed then
			-- sending the stream opening could have failed during an opportunistic write
			return
		end

		session.notopen = nil;
		if session.version >= 1.0 then
			local features = st.stanza("stream:features");

			if to then
				module:context(to):fire_event("s2s-stream-features", { origin = session, features = features });
			else
				(session.log or log)("warn", "No 'to' on stream header from %s means we can't offer any features", from or session.ip or "unknown host");
				module:fire_event("s2s-stream-features-legacy", { origin = session, features = features });
			end

			if ( session.type == "s2sin" or session.type == "s2sout" ) or features.tags[1] then
				if stanza_size_limit or advertised_idle_timeout then
					features:reset();
					local limits = features:tag("limits", { xmlns = "urn:xmpp:stream-limits:0" });
					if stanza_size_limit then
						limits:text_tag("max-bytes", string.format("%d", stanza_size_limit));
					end
					if advertised_idle_timeout then
						limits:text_tag("idle-seconds", string.format("%d", advertised_idle_timeout));
					end
					features:reset();
				end

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
			else
				session.authenticated_remote = true;
			end
		end

		-- If server is pre-1.0, don't wait for features, just do dialback
		if session.version < 1.0 then
			if not session.dialback_verifying then
				module:context(session.from_host):fire_event("s2sout-authenticate-legacy", { origin = session });
			else
				mark_connected(session);
			end
		end
	end
end

function session_events.streamclosed(session)
	(session.log or log)("debug", "Received </stream:stream>");
	session:close(false);
end

function session_events.callback(session, event)
	session.log("debug", "Running session callback %s", event.name);
	event.callback(session, event);
end

function stream_callbacks.streamclosed(session, attr)
	-- run _streamclosed in async context
	session.thread:run({ event = "streamclosed", attr = attr });
end

-- Some stream conditions indicate a problem on our end, e.g. that we sent
-- something invalid. Those should be investigated. Others are problems or
-- events in the remote host that don't affect us, or simply that the
-- connection was closed for being idle.
local stream_condition_severity = {
	["bad-format"] = "warn";
	["bad-namespace-prefix"] = "warn";
	["conflict"] = "warn";
	["connection-timeout"] = "debug";
	["host-gone"] = "info";
	["host-unknown"] = "info";
	["improper-addressing"] = "warn";
	["internal-server-error"] = "warn";
	["invalid-from"] = "warn";
	["invalid-namespace"] = "warn";
	["invalid-xml"] = "warn";
	["not-authorized"] = "warn";
	["not-well-formed"] = "warn";
	["policy-violation"] = "warn";
	["remote-connection-failed"] = "warn";
	["reset"] = "info";
	["resource-constraint"] = "info";
	["restricted-xml"] = "warn";
	["see-other-host"] = "info";
	["system-shutdown"] = "info";
	["undefined-condition"] = "warn";
	["unsupported-encoding"] = "warn";
	["unsupported-feature"] = "warn";
	["unsupported-stanza-type"] = "warn";
	["unsupported-version"] = "warn";
}

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
		session.log(stream_condition_severity[condition] or "info", "Session closed by remote with error: %s", text);
		session:close(nil, text);
	end
end

--- Session methods
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
-- reason: stream error to send to the remote server
-- remote_reason: stream error received from the remote server
-- bounce_reason: stanza error to pass to bounce_sendq because stream- and stanza errors are different
local function session_close(session, reason, remote_reason, bounce_reason)
	local log = session.log or log;
	if not session.conn then
		log("debug", "Attempt to close without associated connection with reason %q", reason);
		return
	end

	local conn = session.conn;
	conn:pause_writes(); -- until :close
	if session.notopen then
		if session.direction == "incoming" then
			session:open_stream(session.to_host, session.from_host);
		else
			session:open_stream(session.from_host, session.to_host);
		end
	end

	local this_host = session.direction == "outgoing" and session.from_host or session.to_host
	if not hosts[this_host] then this_host = ":unknown"; end

	if reason then -- nil == no err, initiated by us, false == initiated by remote
		local stream_error;
		local condition, text, extra
		if type(reason) == "string" then -- assume stream error
			condition = reason
		elseif type(reason) == "table" and not st.is_stanza(reason) then
			condition = reason.condition or "undefined-condition"
			text = reason.text
			extra = reason.extra
		end
		if condition then
			stream_error = st.stanza("stream:error"):tag(condition, stream_xmlns_attr):up();
			if text then
				stream_error:tag("text", stream_xmlns_attr):text(text):up();
			end
			if extra then
				stream_error:add_child(extra);
			end
		end
		if this_host and condition then
			m_closed_connections:with_labels(this_host, session.direction, condition):add(1)
		end
		if st.is_stanza(stream_error) then
			-- to and from are never unknown on outgoing connections
			log("debug", "Disconnecting %s->%s[%s], <stream:error> is: %s",
				session.from_host or "(unknown host)" or session.ip, session.to_host or "(unknown host)", session.type, stream_error);
			session.sends2s(stream_error);
		end
	else
		m_closed_connections:with_labels(this_host or ":unknown", session.direction, reason == false and ":remote-choice" or ":local-choice"):add(1)
	end

	session.sends2s("</stream:stream>");
	function session.sends2s() return false; end

	-- luacheck: ignore 422/reason 412/reason
	-- FIXME reason should be managed in a place common to c2s, s2s, bosh, component etc
	local reason = remote_reason or (reason and (reason.text or reason.condition)) or reason;
	session.log("info", "%s s2s stream %s->%s closed: %s", session.direction:gsub("^.", string.upper),
		session.from_host or "(unknown host)", session.to_host or "(unknown host)", reason or "stream closed");

	conn:resume_writes();

	if session.connect_timeout then
		stop_timer(session.connect_timeout);
		session.connect_timeout = nil;
	end

	-- Authenticated incoming stream may still be sending us stanzas, so wait for </stream:stream> from remote
	if reason == nil and not session.notopen and session.direction == "incoming" then
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
	local stream = new_xmpp_stream(session, stream_callbacks, stanza_size_limit);

	session.thread = runner(function (item)
		if st.is_stanza(item) then
			core_process_stanza(session, item);
		else
			session_events[item.event](session, item);
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

	if conn:ssl() then
		-- Direct TLS was used
		session_secure(session);
	end

	function session.sends2s(t)
		log("debug", "Sending[%s]: %s", session.type, t.top_tag and t:top_tag() or t:match("^[^>]*>?"));
		if t.name then
			t = filter("stanzas/out", t);
		end
		if t then
			t = filter("bytes/out", tostring(t));
			if session.outgoing_stanza_size_limit and #t > session.outgoing_stanza_size_limit then
				log("warn", "Attempt to send a stanza exceeding session limit of %dB (%dB)!", session.outgoing_stanza_size_limit, #t);
				-- TODO Pass identifiable error condition back to allow appropriate handling
				return false
			end
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
			if err == "stanza-too-large" then
				session:close({
					condition = "policy-violation",
					text = "XML stanza is too big",
					extra = st.stanza("stanza-too-big", { xmlns = 'urn:xmpp:errors' }),
				}, nil, "Received invalid XML from remote server");
			else
				session:close("not-well-formed", nil, "Received invalid XML from remote server");
			end
		end
	end

	session.close = session_close;

	local handlestanza = stream_callbacks.handlestanza;
	function session.dispatch_stanza(session, stanza) -- luacheck: ignore 432/session
		return handlestanza(session, stanza);
	end

	module:fire_event("s2s-created", { session = session });

	session.connect_timeout = add_task(connect_timeout, function ()
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
		module:fire_event("s2sin-connected", { session = session })
		initialize_session(session);
		m_accepted_tcp_connections:with_labels():add(1)
	else -- Outgoing session connected
		module:fire_event("s2sout-connected", { session = session })
		session:open_stream(session.from_host, session.to_host);
	end
	module:fire_event("s2s-connected", { session = session })
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
	module:fire_event("s2s-closed", { session = session; conn = conn });
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
		return (hosts[session.host] or prosody).events.fire_event("s2s-read-timeout", { session = session });
	end
end

function listener.ondrain(conn)
	local session = sessions[conn];
	if session then
		return (hosts[session.host] or prosody).events.fire_event("s2s-ondrain", { session = session });
	end
end

function listener.onpredrain(conn)
	local session = sessions[conn];
	if session then
		return (hosts[session.host] or prosody).events.fire_event("s2s-pre-ondrain", { session = session });
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
		if type(session.cert_chain_errors) == "table" then
			local cert_errors = set.new(session.cert_chain_errors[1]);
			if cert_errors:contains("certificate has expired") then
				return "has expired";
			elseif cert_errors:contains("self signed certificate") then
				return "is self-signed";
			elseif cert_errors:contains("no matching DANE TLSA records") then
				return "does not match any DANE TLSA records";
			end

			local chain_errors = set.new(session.cert_chain_errors[2]);
			for i, e in pairs(session.cert_chain_errors) do
				if i > 2 then chain_errors:add_list(e); end
			end
			if chain_errors:contains("certificate has expired") then
				return "has an expired certificate chain";
			elseif chain_errors:contains("no matching DANE TLSA records") then
				return "does not match any DANE TLSA records";
			end
		end
		-- TODO cert_chain_errors can be a string, handle that
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
		--
		-- Note: Bounce message must not include name of server, as it may leak half your JID in semi-anon MUCs.
		session:close({ condition = "not-authorized", text = "Your server's certificate "..reason },
			nil, "Remote server's certificate "..reason);
		return false;
	end
end

module:hook("s2s-check-certificate", check_auth_policy, -1);

module:hook("server-stopping", function(event)
	-- Close ports
	local pm = require "prosody.core.portmanager";
	for _, netservice in pairs(module.items["net-provider"]) do
		pm.unregister_service(netservice.name, netservice);
	end

	-- Stop opening new connections
	for host in pairs(prosody.hosts) do
		if prosody.hosts[host].modules.s2s then
			module:context(host):unhook("route/remote", route_to_new_session);
		end
	end

	local wait, done = async.waiter(1, true);
	module:hook("s2s-closed", function ()
		if next(sessions) == nil then done(); end
	end, 1)

	-- Close sessions
	local reason = event.reason;
	for _, session in pairs(sessions) do
		session:close{ condition = "system-shutdown", text = reason };
	end

	-- Wait for them to close properly if they haven't already
	if next(sessions) ~= nil then
		module:log("info", "Waiting for sessions to close");
		add_task(stream_close_timeout + 1, function () done() end);
		wait();
	end

end, -200);



module:provides("net", {
	name = "s2s";
	listener = listener;
	default_port = 5269;
	encryption = "starttls";
	ssl_config = {
		-- FIXME This only applies to Direct TLS, which we don't use yet.
		-- This gets applied for real in mod_tls
		verify = { "peer", "client_once", };
	};
	multiplex = {
		protocol = "xmpp-server";
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:server%1.*>";
	};
});


module:provides("net", {
	name = "s2s_direct_tls";
	listener = listener;
	encryption = "ssl";
	ssl_config = {
		verify = { "peer", "client_once", };
	};
	multiplex = {
		protocol = "xmpp-server";
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:server%1.*>";
	};
});

