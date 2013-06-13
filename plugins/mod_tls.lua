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

local secure_auth_only = module:get_option("c2s_require_encryption") or module:get_option("require_encryption");
local secure_s2s_only = module:get_option("s2s_require_encryption");
local allow_s2s_tls = module:get_option("s2s_allow_encryption") ~= false;

local xmlns_starttls = 'urn:ietf:params:xml:ns:xmpp-tls';
local starttls_attr = { xmlns = xmlns_starttls };
local starttls_proceed = st.stanza("proceed", starttls_attr);
local starttls_failure = st.stanza("failure", starttls_attr);
local c2s_feature = st.stanza("starttls", starttls_attr);
local s2s_feature = st.stanza("starttls", starttls_attr);
if secure_auth_only then c2s_feature:tag("required"):up(); end
if secure_s2s_only then s2s_feature:tag("required"):up(); end

local hosts = prosody.hosts;
local host = hosts[module.host];

local ssl_ctx_c2s, ssl_ctx_s2sout, ssl_ctx_s2sin;
do
	local function get_ssl_cfg(typ)
		local cfg_key = (typ and typ.."_" or "").."ssl";
		local ssl_config = config.rawget(module.host, cfg_key);
		if not ssl_config then
			local base_host = module.host:match("%.(.*)");
			ssl_config = config.get(base_host, cfg_key);
		end
		return ssl_config or typ and get_ssl_cfg();
	end

	local ssl_config, err = get_ssl_cfg("c2s");
	ssl_ctx_c2s, err = create_context(host.host, "server", ssl_config); -- for incoming client connections
	if err then module:log("error", "Error creating context for c2s: %s", err); end

	ssl_config = get_ssl_cfg("s2s");
	ssl_ctx_s2sin, err = create_context(host.host, "server", ssl_config); -- for incoming server connections
	ssl_ctx_s2sout = create_context(host.host, "client", ssl_config); -- for outgoing server connections
	if err then module:log("error", "Error creating context for s2s: %s", err); end -- Both would have the same issue
end

local function can_do_tls(session)
	if not session.conn.starttls then
		return false;
	elseif session.ssl_ctx then
		return true;
	end
	if session.type == "c2s_unauthed" then
		module:log("debug", "session.ssl_ctx = ssl_ctx_c2s;")
		session.ssl_ctx = ssl_ctx_c2s;
	elseif session.type == "s2sin_unauthed" and allow_s2s_tls then
		session.ssl_ctx = ssl_ctx_s2sin;
	elseif session.direction == "outgoing" and allow_s2s_tls then
		session.ssl_ctx = ssl_ctx_s2sout;
	else
		return false;
	end
	return session.ssl_ctx;
end

-- Hook <starttls/>
module:hook("stanza/urn:ietf:params:xml:ns:xmpp-tls:starttls", function(event)
	local origin = event.origin;
	if can_do_tls(origin) then
		(origin.sends2s or origin.send)(starttls_proceed);
		origin:reset_stream();
		origin.conn:starttls(origin.ssl_ctx);
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
	session.conn:starttls(session.ssl_ctx);
	session.secure = false;
	return true;
end);
