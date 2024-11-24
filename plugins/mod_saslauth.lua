-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 431/log


local st = require "prosody.util.stanza";
local sm_bind_resource = require "prosody.core.sessionmanager".bind_resource;
local sm_make_authenticated = require "prosody.core.sessionmanager".make_authenticated;
local base64 = require "prosody.util.encodings".base64;
local set = require "prosody.util.set";
local errors = require "prosody.util.error";
local hex = require "prosody.util.hex";
local pem2der = require"prosody.util.x509".pem2der;
local hashes = require "prosody.util.hashes";
local ssl = require "ssl"; -- FIXME Isolate LuaSec from the rest of the code

local certmanager = require "prosody.core.certmanager";
local pm_get_tls_config_at = require "prosody.core.portmanager".get_tls_config_at;
local usermanager_get_sasl_handler = require "prosody.core.usermanager".get_sasl_handler;

local secure_auth_only = module:get_option_boolean("c2s_require_encryption", module:get_option_boolean("require_encryption", true));
local allow_unencrypted_plain_auth = module:get_option_boolean("allow_unencrypted_plain_auth", false)
local insecure_mechanisms = module:get_option_set("insecure_sasl_mechanisms", allow_unencrypted_plain_auth and {} or {"PLAIN", "LOGIN"});
local disabled_mechanisms = module:get_option_set("disable_sasl_mechanisms", { "DIGEST-MD5" });
local tls_server_end_point_hash = module:get_option_string("tls_server_end_point_hash");

local log = module._log;

local xmlns_sasl ='urn:ietf:params:xml:ns:xmpp-sasl';
local xmlns_bind ='urn:ietf:params:xml:ns:xmpp-bind';

local function build_reply(status, ret, err_msg)
	local reply = st.stanza(status, {xmlns = xmlns_sasl});
	if status == "failure" then
		reply:tag(ret):up();
		if err_msg then reply:tag("text"):text(err_msg); end
	elseif status == "challenge" or status == "success" then
		if ret == "" then
			reply:text("=")
		elseif ret then
			reply:text(base64.encode(ret));
		end
	else
		module:log("error", "Unknown sasl status: %s", status);
	end
	return reply;
end

local function handle_status(session, status, ret, err_msg)
	if not session.sasl_handler then
		return "failure", "temporary-auth-failure", "Connection gone";
	end
	if status == "failure" then
		local event = { session = session, condition = ret, text = err_msg };
		module:fire_event("authentication-failure", event);
		session.sasl_handler = session.sasl_handler:clean_clone();
		ret, err_msg = event.condition, event.text;
	elseif status == "success" then
		local ok, err = sm_make_authenticated(session, session.sasl_handler.username, session.sasl_handler.role);
		if ok then
			session.sasl_resource = session.sasl_handler.resource;
			module:fire_event("authentication-success", { session = session });
			session.sasl_handler = nil;
			session:reset_stream();
		else
			module:log("warn", "SASL succeeded but username was invalid");
			module:fire_event("authentication-failure", { session = session, condition = "not-authorized", text = err });
			session.sasl_handler = session.sasl_handler:clean_clone();
			return "failure", "not-authorized", "User authenticated successfully, but username was invalid";
		end
	end
	return status, ret, err_msg;
end

local function sasl_process_cdata(session, stanza)
	local text = stanza[1];
	if text then
		text = base64.decode(text);
		if not text then
			session.sasl_handler = nil;
			session.send(build_reply("failure", "incorrect-encoding"));
			return true;
		end
	end
	local sasl_handler = session.sasl_handler;
	local status, ret, err_msg = sasl_handler:process(text);
	status, ret, err_msg = handle_status(session, status, ret, err_msg);
	local event = { session = session, message = ret, error_text = err_msg };
	module:fire_event("sasl/"..session.base_type.."/"..status, event);
	local s = build_reply(status, event.message, event.error_text);
	session.send(s);
	return true;
end

module:hook_tag(xmlns_sasl, "success", function (session)
	if session.type ~= "s2sout_unauthed" or session.external_auth ~= "attempting" then return; end
	module:log("debug", "SASL EXTERNAL with %s succeeded", session.to_host);
	session.external_auth = "succeeded"
	session:reset_stream();
	session:open_stream(session.from_host, session.to_host);

	module:fire_event("s2s-authenticated", { session = session, host = session.to_host, mechanism = "EXTERNAL" });
	return true;
end)

module:hook_tag(xmlns_sasl, "failure", function (session, stanza)
	if session.type ~= "s2sout_unauthed" or session.external_auth ~= "attempting" then return; end

	local text = stanza:get_child_text("text");
	local condition = "unknown-condition";
	for child in stanza:childtags() do
		if child.name ~= "text" then
			condition = child.name;
			break;
		end
	end
	local err = errors.new({
			-- TODO type = what?
			text = text,
			condition = condition,
		}, {
			session = session,
			stanza = stanza,
		});

	module:log("info", "SASL EXTERNAL with %s failed: %s", session.to_host, err);

	session.external_auth = "failed"
	session.external_auth_failure_reason = err;
end, 500)

module:hook_tag(xmlns_sasl, "failure", function (session, stanza) -- luacheck: ignore 212/stanza
	session.log("debug", "No fallback from SASL EXTERNAL failure, giving up");
	session:close(nil, session.external_auth_failure_reason, errors.new({
				type = "wait", condition = "remote-server-timeout",
				text = "Could not authenticate to remote server",
		}, { session = session, sasl_failure = session.external_auth_failure_reason, }));
	return true;
end, 90)

module:hook_tag("http://etherx.jabber.org/streams", "features", function (session, stanza)
	if session.type ~= "s2sout_unauthed" or not session.secure then return; end

	local mechanisms = stanza:get_child("mechanisms", xmlns_sasl)
	if mechanisms then
		for mech in mechanisms:childtags() do
			if mech[1] == "EXTERNAL" then
				module:log("debug", "Initiating SASL EXTERNAL with %s", session.to_host);
				local reply = st.stanza("auth", {xmlns = xmlns_sasl, mechanism = "EXTERNAL"});
				reply:text(base64.encode(session.from_host))
				session.sends2s(reply)
				session.external_auth = "attempting"
				return true
			end
		end
	end
end, 150);

local function s2s_external_auth(session, stanza)
	if session.external_auth ~= "offered" then return end -- Unexpected request

	local mechanism = stanza.attr.mechanism;

	if mechanism ~= "EXTERNAL" then
		session.sends2s(build_reply("failure", "invalid-mechanism"));
		return true;
	end

	if not session.secure then
		session.sends2s(build_reply("failure", "encryption-required"));
		return true;
	end

	local text = stanza[1];
	if not text then
		session.sends2s(build_reply("failure", "malformed-request"));
		return true;
	end

	text = base64.decode(text);
	if not text then
		session.sends2s(build_reply("failure", "incorrect-encoding"));
		return true;
	end

	-- The text value is either "" or equals session.from_host
	if not ( text == "" or text == session.from_host ) then
		session.sends2s(build_reply("failure", "invalid-authzid"));
		return true;
	end

	-- We've already verified the external cert identity before offering EXTERNAL
	if session.cert_chain_status ~= "valid" or session.cert_identity_status ~= "valid" then
		session.sends2s(build_reply("failure", "not-authorized"));
		session:close();
		return true;
	end

	-- Success!
	session.external_auth = "succeeded";
	session.sends2s(build_reply("success"));
	module:log("info", "Accepting SASL EXTERNAL identity from %s", session.from_host);
	module:fire_event("s2s-authenticated", { session = session, host = session.from_host, mechanism = mechanism });
	session:reset_stream();
	return true;
end

module:hook("stanza/urn:ietf:params:xml:ns:xmpp-sasl:auth", function(event)
	local session, stanza = event.origin, event.stanza;
	if session.type == "s2sin_unauthed" then
		return s2s_external_auth(session, stanza)
	end

	if session.type ~= "c2s_unauthed" or module:get_host_type() ~= "local" then return; end

	-- event for preemptive checks, rate limiting etc
	module:fire_event("authentication-attempt", event);
	if event.allowed == false then
		session.send(build_reply("failure", event.error_condition or "not-authorized", event.error_text));
		return true;
	end
	if session.sasl_handler and session.sasl_handler.selected then
		session.sasl_handler = nil; -- allow starting a new SASL negotiation before completing an old one
	end
	if not session.sasl_handler then
		session.sasl_handler = usermanager_get_sasl_handler(module.host, session);
	end
	local mechanism = stanza.attr.mechanism;
	if not session.secure and (secure_auth_only or insecure_mechanisms:contains(mechanism)) then
		session.send(build_reply("failure", "encryption-required"));
		return true;
	elseif disabled_mechanisms:contains(mechanism) then
		session.send(build_reply("failure", "invalid-mechanism"));
		return true;
	end
	local valid_mechanism = session.sasl_handler:select(mechanism);
	if not valid_mechanism then
		session.send(build_reply("failure", "invalid-mechanism"));
		return true;
	end
	return sasl_process_cdata(session, stanza);
end);
module:hook("stanza/urn:ietf:params:xml:ns:xmpp-sasl:response", function(event)
	local session = event.origin;
	if not(session.sasl_handler and session.sasl_handler.selected) then
		session.send(build_reply("failure", "not-authorized", "Out of order SASL element"));
		return true;
	end
	return sasl_process_cdata(session, event.stanza);
end);
module:hook("stanza/urn:ietf:params:xml:ns:xmpp-sasl:abort", function(event)
	local session = event.origin;
	session.sasl_handler = nil;
	session.send(build_reply("failure", "aborted"));
	return true;
end);

local function tls_unique(self)
	return self.userdata["tls-unique"]:ssl_peerfinished();
end

local function tls_exporter(conn)
	if not conn.ssl_exportkeyingmaterial then return end
	return conn:ssl_exportkeyingmaterial("EXPORTER-Channel-Binding", 32, "");
end

local function sasl_tls_exporter(self)
	return tls_exporter(self.userdata["tls-exporter"]);
end

local function tls_server_end_point(self)
	local cert_hash = self.userdata["tls-server-end-point"];
	if cert_hash then return hex.from(cert_hash); end

	local conn = self.userdata["tls-server-end-point-conn"];
	local cert = conn.getlocalcertificate and conn:getlocalcertificate();

	if not cert then
		-- We don't know that this is the right cert, it could have been replaced on
		-- disk since we started.
		local certfile = self.userdata["tls-server-end-point-cert"];
		if not certfile then return end
		local f = io.open(certfile);
		if not f then return end
		local certdata = f:read("*a");
		f:close();
		cert = ssl.loadcertificate(certdata);
	end

	-- Hash function selection, see RFC 5929 §4.1
	local hash, hash_name = hashes.sha256, "sha256";
	if cert.getsignaturename then
		local sigalg = cert:getsignaturename():lower():match("sha%d+");
		if sigalg and sigalg ~= "sha1" and hashes[sigalg] then
			-- This should have ruled out MD5 and SHA1
			hash, hash_name = hashes[sigalg], sigalg;
		end
	end

	local certdata_der = pem2der(cert:pem());
	local hashed_der = hash(certdata_der);

	module:log("debug", "tls-server-end-point: hex(%s(der)) = %q, hash = %s", hash_name, hex.encode(hashed_der));

	return hashed_der;
end

local mechanisms_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-sasl' };
local bind_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-bind' };
local xmpp_session_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-session' };
module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	local log = origin.log or log;
	if not origin.username then
		if secure_auth_only and not origin.secure then
			log("debug", "Not offering authentication on insecure connection");
			return;
		end
		local sasl_handler = usermanager_get_sasl_handler(module.host, origin)
		origin.sasl_handler = sasl_handler;
		local channel_bindings = set.new()
		if origin.encrypted then
			-- check whether LuaSec has the nifty binding to the function needed for tls-unique
			-- FIXME: would be nice to have this check only once and not for every socket
			if sasl_handler.add_cb_handler then
				local info = origin.conn:ssl_info();
				if info and info.protocol == "TLSv1.3" then
					log("debug", "Channel binding 'tls-unique' undefined in context of TLS 1.3");
					if tls_exporter(origin.conn) then
						log("debug", "Channel binding 'tls-exporter' supported");
						sasl_handler:add_cb_handler("tls-exporter", sasl_tls_exporter);
						channel_bindings:add("tls-exporter");
					else
						log("debug", "Channel binding 'tls-exporter' not supported");
					end
				elseif origin.conn.ssl_peerfinished and origin.conn:ssl_peerfinished() then
					log("debug", "Channel binding 'tls-unique' supported");
					sasl_handler:add_cb_handler("tls-unique", tls_unique);
					channel_bindings:add("tls-unique");
				else
					log("debug", "Channel binding 'tls-unique' not supported (by LuaSec?)");
				end

				local certfile;
				if tls_server_end_point_hash == "auto" then
					tls_server_end_point_hash = nil;
					local ssl_cfg = origin.ssl_cfg;
					if not ssl_cfg then
						local server = origin.conn:server();
						local tls_config = pm_get_tls_config_at(server:ip(), server:serverport());
						local autocert = certmanager.find_host_cert(origin.conn:socket():getsniname());
						ssl_cfg = autocert or tls_config;
					end

					certfile = ssl_cfg and ssl_cfg.certificate;
					if certfile then
						log("debug", "Channel binding 'tls-server-end-point' can be offered based on the certificate used");
						sasl_handler:add_cb_handler("tls-server-end-point", tls_server_end_point);
						channel_bindings:add("tls-server-end-point");
					else
						log("debug", "Channel binding 'tls-server-end-point' set to 'auto' but cannot determine cert");
					end
				elseif tls_server_end_point_hash then
					log("debug", "Channel binding 'tls-server-end-point' can be offered with the configured certificate hash");
					sasl_handler:add_cb_handler("tls-server-end-point", tls_server_end_point);
					channel_bindings:add("tls-server-end-point");
				end

				sasl_handler["userdata"] = {
					["tls-unique"] = origin.conn;
					["tls-exporter"] = origin.conn;
					["tls-server-end-point-cert"] = certfile;
					["tls-server-end-point-conn"] = origin.conn;
					["tls-server-end-point"] = tls_server_end_point_hash;
				};
			else
				log("debug", "Channel binding not supported by SASL handler");
			end
		end
		local mechanisms = st.stanza("mechanisms", mechanisms_attr);
		local sasl_mechanisms = sasl_handler:mechanisms()
		local available_mechanisms = set.new();
		for mechanism in pairs(sasl_mechanisms) do
			available_mechanisms:add(mechanism);
		end
		log("debug", "SASL mechanisms supported by handler: %s", available_mechanisms);

		local usable_mechanisms = available_mechanisms - disabled_mechanisms;

		local available_disabled = set.intersection(available_mechanisms, disabled_mechanisms);
		if not available_disabled:empty() then
			log("debug", "Not offering disabled mechanisms: %s", available_disabled);
		end

		local available_insecure = set.intersection(available_mechanisms, insecure_mechanisms);
		if not origin.secure and not available_insecure:empty() then
			log("debug", "Session is not secure, not offering insecure mechanisms: %s", available_insecure);
			usable_mechanisms = usable_mechanisms - insecure_mechanisms;
		end

		if not usable_mechanisms:empty() then
			log("debug", "Offering usable mechanisms: %s", usable_mechanisms);
			for mechanism in usable_mechanisms do
				mechanisms:tag("mechanism"):text(mechanism):up();
			end
			features:add_child(mechanisms);
			if not channel_bindings:empty() then
				-- XXX XEP-0440 is Experimental
				features:tag("sasl-channel-binding", {xmlns='urn:xmpp:sasl-cb:0'})
				for channel_binding in channel_bindings do
					features:tag("channel-binding", {type=channel_binding}):up()
				end
				features:up();
			end
			return;
		end

		local authmod = module:get_option_string("authentication", "internal_hashed");
		if available_mechanisms:empty() then
			log("warn", "No available SASL mechanisms, verify that the configured authentication module '%s' is loaded and configured correctly", authmod);
			return;
		end

		if not origin.secure and not available_insecure:empty() then
			if not available_disabled:empty() then
				log("warn", "All SASL mechanisms provided by authentication module '%s' are forbidden on insecure connections (%s) or disabled (%s)",
					authmod, available_insecure, available_disabled);
			else
				log("warn", "All SASL mechanisms provided by authentication module '%s' are forbidden on insecure connections (%s)",
					authmod, available_insecure);
			end
		elseif not available_disabled:empty() then
			log("warn", "All SASL mechanisms provided by authentication module '%s' are disabled (%s)",
				authmod, available_disabled);
		end

	elseif not origin.full_jid then
		features:tag("bind", bind_attr):tag("required"):up():up();
		features:tag("session", xmpp_session_attr):tag("optional"):up():up();
	end
end);

module:hook("s2s-stream-features", function(event)
	local origin, features = event.origin, event.features;
	if origin.secure and origin.type == "s2sin_unauthed" then
		-- Offer EXTERNAL only if both chain and identity is valid.
		if origin.cert_chain_status == "valid" and origin.cert_identity_status == "valid" then
			module:log("debug", "Offering SASL EXTERNAL");
			origin.external_auth = "offered"
			features:tag("mechanisms", { xmlns = xmlns_sasl })
				:tag("mechanism"):text("EXTERNAL")
			:up():up();
		end
	end
end);

module:hook("stanza/iq/urn:ietf:params:xml:ns:xmpp-bind:bind", function(event)
	local origin, stanza = event.origin, event.stanza;
	local resource = origin.sasl_resource;
	if stanza.attr.type == "set" and not resource then
		local bind = stanza.tags[1];
		resource = bind:get_child("resource");
		resource = resource and #resource.tags == 0 and resource[1] or nil;
	end
	local success, err_type, err, err_msg = sm_bind_resource(origin, resource);
	if success then
		origin.sasl_resource = nil;
		origin.send(st.reply(stanza)
			:tag("bind", { xmlns = xmlns_bind })
			:tag("jid"):text(origin.full_jid));
		origin.log("debug", "Resource bound: %s", origin.full_jid);
	else
		origin.send(st.error_reply(stanza, err_type, err, err_msg));
		origin.log("debug", "Resource bind failed: %s", err_msg or err);
	end
	return true;
end);

local function handle_legacy_session(event)
	event.origin.send(st.reply(event.stanza));
	return true;
end

module:hook("iq/self/urn:ietf:params:xml:ns:xmpp-session:session", handle_legacy_session);
module:hook("iq/host/urn:ietf:params:xml:ns:xmpp-session:session", handle_legacy_session);
