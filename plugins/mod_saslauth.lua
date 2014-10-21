-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza";
local sm_bind_resource = require "core.sessionmanager".bind_resource;
local sm_make_authenticated = require "core.sessionmanager".make_authenticated;
local base64 = require "util.encodings".base64;

local usermanager_get_sasl_handler = require "core.usermanager".get_sasl_handler;
local tostring = tostring;

local secure_auth_only = module:get_option_boolean("c2s_require_encryption", module:get_option_boolean("require_encryption", false));
local allow_unencrypted_plain_auth = module:get_option_boolean("allow_unencrypted_plain_auth", false)
local insecure_mechanisms = module:get_option_set("allow_unencrypted_sasl", allow_unencrypted_plain_auth and {} or {"PLAIN", "LOGIN"});

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
	if status == "failure" then
		module:fire_event("authentication-failure", { session = session, condition = ret, text = err_msg });
		session.sasl_handler = session.sasl_handler:clean_clone();
	elseif status == "success" then
		local ok, err = sm_make_authenticated(session, session.sasl_handler.username);
		if ok then
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
		--log("debug", "AUTH: %s", text:gsub("[%z\001-\008\011\012\014-\031]", " "));
		if not text then
			session.sasl_handler = nil;
			session.send(build_reply("failure", "incorrect-encoding"));
			return true;
		end
	end
	local status, ret, err_msg = session.sasl_handler:process(text);
	status, ret, err_msg = handle_status(session, status, ret, err_msg);
	local s = build_reply(status, ret, err_msg);
	log("debug", "sasl reply: %s", tostring(s));
	session.send(s);
	return true;
end

module:hook_stanza(xmlns_sasl, "success", function (session, stanza)
	if session.type ~= "s2sout_unauthed" or session.external_auth ~= "attempting" then return; end
	module:log("debug", "SASL EXTERNAL with %s succeeded", session.to_host);
	session.external_auth = "succeeded"
	session:reset_stream();
	session:open_stream(session.from_host, session.to_host);

	module:fire_event("s2s-authenticated", { session = session, host = session.to_host });
	return true;
end)

module:hook_stanza(xmlns_sasl, "failure", function (session, stanza)
	if session.type ~= "s2sout_unauthed" or session.external_auth ~= "attempting" then return; end

	module:log("info", "SASL EXTERNAL with %s failed", session.to_host)
	-- TODO: Log the failure reason
	session.external_auth = "failed"
	session:close();
	return true;
end, 500)

module:hook_stanza("http://etherx.jabber.org/streams", "features", function (session, stanza)
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
	module:fire_event("s2s-authenticated", { session = session, host = session.from_host });
	session:reset_stream();
	return true;
end

module:hook("stanza/urn:ietf:params:xml:ns:xmpp-sasl:auth", function(event)
	local session, stanza = event.origin, event.stanza;
	if session.type == "s2sin_unauthed" then
		return s2s_external_auth(session, stanza)
	end

	if session.type ~= "c2s_unauthed" or module:get_host_type() ~= "local" then return; end

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

local mechanisms_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-sasl' };
local bind_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-bind' };
local xmpp_session_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-session' };
module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if not origin.username then
		if secure_auth_only and not origin.secure then
			return;
		end
		origin.sasl_handler = usermanager_get_sasl_handler(module.host, origin);
		if origin.encrypted then
			-- check wether LuaSec has the nifty binding to the function needed for tls-unique
			-- FIXME: would be nice to have this check only once and not for every socket
			if origin.conn:socket().getpeerfinished and origin.sasl_handler.add_cb_handler then
				origin.sasl_handler:add_cb_handler("tls-unique", function(self)
					return self.userdata:getpeerfinished();
				end);
				origin.sasl_handler["userdata"] = origin.conn:socket();
			end
		end
		local mechanisms = st.stanza("mechanisms", mechanisms_attr);
		for mechanism in pairs(origin.sasl_handler:mechanisms()) do
			if (origin.secure or not insecure_mechanisms:contains(mechanism)) then
				mechanisms:tag("mechanism"):text(mechanism):up();
			end
		end
		if mechanisms[1] then
			features:add_child(mechanisms);
		else
			(origin.log or log)("warn", "No SASL mechanisms to offer");
		end
	else
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

module:hook("iq/self/urn:ietf:params:xml:ns:xmpp-bind:bind", function(event)
	local origin, stanza = event.origin, event.stanza;
	local resource;
	if stanza.attr.type == "set" then
		local bind = stanza.tags[1];
		resource = bind:get_child("resource");
		resource = resource and #resource.tags == 0 and resource[1] or nil;
	end
	local success, err_type, err, err_msg = sm_bind_resource(origin, resource);
	if success then
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
