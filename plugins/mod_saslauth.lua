-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza";
local sm_bind_resource = require "core.sessionmanager".bind_resource;
local sm_make_authenticated = require "core.sessionmanager".make_authenticated;
local base64 = require "util.encodings".base64;

local nodeprep = require "util.encodings".stringprep.nodeprep;
local datamanager_load = require "util.datamanager".load;
local usermanager_validate_credentials = require "core.usermanager".validate_credentials;
local usermanager_get_supported_methods = require "core.usermanager".get_supported_methods;
local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_get_password = require "core.usermanager".get_password;
local t_concat, t_insert = table.concat, table.insert;
local tostring = tostring;
local jid_split = require "util.jid".split
local md5 = require "util.hashes".md5;
local config = require "core.configmanager";

local secure_auth_only = module:get_option("c2s_require_encryption") or module:get_option("require_encryption");
local sasl_backend = module:get_option("sasl_backend") or "builtin";

local log = module._log;

local xmlns_sasl ='urn:ietf:params:xml:ns:xmpp-sasl';
local xmlns_bind ='urn:ietf:params:xml:ns:xmpp-bind';
local xmlns_stanzas ='urn:ietf:params:xml:ns:xmpp-stanzas';

local new_sasl
if sasl_backend == "cyrus" then
	local cyrus_new = require "util.sasl_cyrus".new;
	new_sasl = function(realm)
			return cyrus_new(realm, module:get_option("cyrus_service_name") or "xmpp")
		end
else
	if sasl_backend ~= "builtin" then module:log("warn", "Unknown SASL backend %s", sasl_backend) end;
	new_sasl = require "util.sasl".new;
end

local default_authentication_profile = {
	plain = function(username, realm)
		local prepped_username = nodeprep(username);
		if not prepped_username then
			log("debug", "NODEprep failed on username: %s", username);
			return "", nil;
		end
		local password = usermanager_get_password(prepped_username, realm);
		if not password then
			return "", nil;
		end
		return password, true;
	end
};

local anonymous_authentication_profile = {
	anonymous = function(username, realm)
		return true; -- for normal usage you should always return true here
	end
};

local function build_reply(status, ret, err_msg)
	local reply = st.stanza(status, {xmlns = xmlns_sasl});
	if status == "challenge" then
		log("debug", "%s", ret or "");
		reply:text(base64.encode(ret or ""));
	elseif status == "failure" then
		reply:tag(ret):up();
		if err_msg then reply:tag("text"):text(err_msg); end
	elseif status == "success" then
		log("debug", "%s", ret or "");
		reply:text(base64.encode(ret or ""));
	else
		module:log("error", "Unknown sasl status: %s", status);
	end
	return reply;
end

local function handle_status(session, status)
	if status == "failure" then
		session.sasl_handler = session.sasl_handler:clean_clone();
	elseif status == "success" then
		local username = nodeprep(session.sasl_handler.username);
		if not username then -- TODO move this to sessionmanager
			module:log("warn", "SASL succeeded but we didn't get a username!");
			session.sasl_handler = nil;
			session:reset_stream();
			return;
		end
		sm_make_authenticated(session, session.sasl_handler.username);
		session.sasl_handler = nil;
		session:reset_stream();
	end
end

local function sasl_handler(session, stanza)
	if stanza.name == "auth" then
		-- FIXME ignoring duplicates because ejabberd does
		if config.get(session.host or "*", "core", "anonymous_login") then
			if stanza.attr.mechanism ~= "ANONYMOUS" then
				return session.send(build_reply("failure", "invalid-mechanism"));
			end
		elseif stanza.attr.mechanism == "ANONYMOUS" then
			return session.send(build_reply("failure", "mechanism-too-weak"));
		end
		local valid_mechanism = session.sasl_handler:select(stanza.attr.mechanism);
		if not valid_mechanism then
			return session.send(build_reply("failure", "invalid-mechanism"));
		end
		if secure_auth_only and not session.secure then
			return session.send(build_reply("failure", "encryption-required"));
		end
	elseif not session.sasl_handler then
		return; -- FIXME ignoring out of order stanzas because ejabberd does
	end
	local text = stanza[1];
	if text then
		text = base64.decode(text);
		log("debug", "%s", text:gsub("[%z\001-\008\011\012\014-\031]", " "));
		if not text then
			session.sasl_handler = nil;
			session.send(build_reply("failure", "incorrect-encoding"));
			return;
		end
	end
	local status, ret, err_msg = session.sasl_handler:process(text);
	handle_status(session, status);
	local s = build_reply(status, ret, err_msg);
	log("debug", "sasl reply: %s", tostring(s));
	session.send(s);
end

module:add_handler("c2s_unauthed", "auth", xmlns_sasl, sasl_handler);
module:add_handler("c2s_unauthed", "abort", xmlns_sasl, sasl_handler);
module:add_handler("c2s_unauthed", "response", xmlns_sasl, sasl_handler);

local mechanisms_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-sasl' };
local bind_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-bind' };
local xmpp_session_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-session' };
module:add_event_hook("stream-features",
		function (session, features)
			if not session.username then
				if secure_auth_only and not session.secure then
					return;
				end
				if module:get_option("anonymous_login") then
					session.sasl_handler = new_sasl(session.host, anonymous_authentication_profile);
				else
					session.sasl_handler = new_sasl(session.host, default_authentication_profile);
					if not (module:get_option("allow_unencrypted_plain_auth")) and not session.secure then
						session.sasl_handler:forbidden({"PLAIN"});
					end
				end
				features:tag("mechanisms", mechanisms_attr);
				for k, v in pairs(session.sasl_handler:mechanisms()) do
					features:tag("mechanism"):text(v):up();
				end
				features:up();
			else
				features:tag("bind", bind_attr):tag("required"):up():up();
				features:tag("session", xmpp_session_attr):tag("optional"):up():up();
			end
		end);

module:add_iq_handler("c2s", "urn:ietf:params:xml:ns:xmpp-bind",
		function (session, stanza)
			log("debug", "Client requesting a resource bind");
			local resource;
			if stanza.attr.type == "set" then
				local bind = stanza.tags[1];
				if bind and bind.attr.xmlns == xmlns_bind then
					resource = bind:child_with_name("resource");
					if resource then
						resource = resource[1];
					end
				end
			end
			local success, err_type, err, err_msg = sm_bind_resource(session, resource);
			if not success then
				session.send(st.error_reply(stanza, err_type, err, err_msg));
			else
				session.send(st.reply(stanza)
					:tag("bind", { xmlns = xmlns_bind})
					:tag("jid"):text(session.full_jid));
			end
		end);

module:add_iq_handler("c2s", "urn:ietf:params:xml:ns:xmpp-session",
		function (session, stanza)
			log("debug", "Client requesting a session");
			session.send(st.reply(stanza));
		end);
