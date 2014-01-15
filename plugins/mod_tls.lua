-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local config = require "core.configmanager";
local create_context = require "core.certmanager".create_context;
local st = require "util.stanza";

local c2s_require_encryption = module:get_option("c2s_require_encryption") or module:get_option("require_encryption");
local s2s_require_encryption = module:get_option("s2s_require_encryption");
local allow_s2s_tls = module:get_option("s2s_allow_encryption") ~= false;

local xmlns_starttls = 'urn:ietf:params:xml:ns:xmpp-tls';
local starttls_attr = { xmlns = xmlns_starttls };
local starttls_proceed = st.stanza("proceed", starttls_attr);
local starttls_failure = st.stanza("failure", starttls_attr);
local c2s_feature = st.stanza("starttls", starttls_attr);
local s2s_feature = st.stanza("starttls", starttls_attr);
if c2s_require_encryption then c2s_feature:tag("required"):up(); end
if s2s_require_encryption then s2s_feature:tag("required"):up(); end

local global_ssl_ctx = prosody.global_ssl_ctx;

local hosts = prosody.hosts;
local host = hosts[module.host];

local function can_do_tls(session)
	if session.type == "c2s_unauthed" then
		return session.conn.starttls and host.ssl_ctx_in;
	elseif session.type == "s2sin_unauthed" and allow_s2s_tls then
		return session.conn.starttls and host.ssl_ctx_in;
	elseif session.direction == "outgoing" and allow_s2s_tls then
		return session.conn.starttls and host.ssl_ctx;
	end
	return false;
end

-- Hook <starttls/>
module:hook("stanza/urn:ietf:params:xml:ns:xmpp-tls:starttls", function(event)
	local origin = event.origin;
	if can_do_tls(origin) then
		(origin.sends2s or origin.send)(starttls_proceed);
		origin:reset_stream();
		local host = origin.to_host or origin.host;
		local ssl_ctx = host and hosts[host].ssl_ctx_in or global_ssl_ctx;
		origin.conn:starttls(ssl_ctx);
		origin.log("debug", "TLS negotiation started for %s...", origin.type);
		origin.secure = false;
	else
		origin.log("warn", "Attempt to start TLS, but TLS is not available on this %s connection", origin.type);
		(origin.sends2s or origin.send)(starttls_failure);
		origin:close();
	end
	return true;
end);

-- Advertize stream feature
module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if can_do_tls(origin) then
		features:add_child(c2s_feature);
	end
end);
module:hook("s2s-stream-features", function(event)
	local origin, features = event.origin, event.features;
	if can_do_tls(origin) then
		features:add_child(s2s_feature);
	end
end);

-- For s2sout connections, start TLS if we can
module:hook_stanza("http://etherx.jabber.org/streams", "features", function (session, stanza)
	module:log("debug", "Received features element");
	if can_do_tls(session) and stanza:child_with_ns(xmlns_starttls) then
		module:log("debug", "%s is offering TLS, taking up the offer...", session.to_host);
		session.sends2s("<starttls xmlns='"..xmlns_starttls.."'/>");
		return true;
	end
end, 500);

module:hook_stanza(xmlns_starttls, "proceed", function (session, stanza)
	module:log("debug", "Proceeding with TLS on s2sout...");
	session:reset_stream();
	local ssl_ctx = session.from_host and hosts[session.from_host].ssl_ctx or global_ssl_ctx;
	session.conn:starttls(ssl_ctx);
	session.secure = false;
	return true;
end);

local function assert_log(ret, err)
	if not ret then
		module:log("error", "Unable to initialize TLS: %s", err);
	end
	return ret;
end

function module.load()
	local ssl_config = config.rawget(module.host, "ssl");
	if not ssl_config then
		local base_host = module.host:match("%.(.*)");
		ssl_config = config.get(base_host, "ssl");
	end
	host.ssl_ctx = assert_log(create_context(host.host, "client", ssl_config)); -- for outgoing connections
	host.ssl_ctx_in = assert_log(create_context(host.host, "server", ssl_config)); -- for incoming connections
end

function module.unload()
	host.ssl_ctx = nil;
	host.ssl_ctx_in = nil;
end
