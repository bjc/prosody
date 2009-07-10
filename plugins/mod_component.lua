-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

if module:get_host_type() ~= "component" then
	error("Don't load mod_component manually, it should be for a component, please see http://prosody.im/doc/components", 0);
end

local hosts = _G.hosts;

local t_concat = table.concat;

local lxp = require "lxp";
local logger = require "util.logger";
local config = require "core.configmanager";
local connlisteners = require "net.connlisteners";
local cm_register_component = require "core.componentmanager".register_component;
local cm_deregister_component = require "core.componentmanager".deregister_component;
local uuid_gen = require "util.uuid".generate;
local sha1 = require "util.hashes".sha1;
local st = require "util.stanza";
local init_xmlhandlers = require "core.xmlhandlers";

local sessions = {};

local log = module._log;

local component_listener = { default_port = 5347; default_mode = "*a"; default_interface = config.get("*", "core", "component_interface") or "127.0.0.1" };

local xmlns_component = 'jabber:component:accept';

--- Handle authentication attempts by components
function handle_component_auth(session, stanza)
	log("info", "Handling component auth");
	if (not session.host) or #stanza.tags > 0 then
		(session.log or log)("warn", "Component handshake invalid");
		session:close("not-authorized");
		return;
	end
	
	local secret = config.get(session.user, "core", "component_secret");
	if not secret then
		(session.log or log)("warn", "Component attempted to identify as %s, but component_password is not set", session.user);
		session:close("not-authorized");
		return;
	end
	
	local supplied_token = t_concat(stanza);
	local calculated_token = sha1(session.streamid..secret, true);
	if supplied_token:lower() ~= calculated_token:lower() then
		log("info", "Component for %s authentication failed", session.host);
		session:close{ condition = "not-authorized", text = "Given token does not match calculated token" };
		return;
	end
	
	
	-- Authenticated now
	log("info", "Component authenticated: %s", session.host);
	
	-- If component not already created for this host, create one now
	if not hosts[session.host].connected then
		local send = session.send;
		session.component_session = cm_register_component(session.host, function (_, data) 
				if data.attr and data.attr.xmlns == "jabber:client" then
					data.attr.xmlns = nil;
				end
				return send(data);
			end);
		hosts[session.host].connected = true;
		log("info", "Component successfully registered");
	else
		log("error", "Multiple components bound to the same address, first one wins (TODO: Implement stanza distribution)");
	end
	
	-- Signal successful authentication
	session.send(st.stanza("handshake"));
end

module:add_handler("component", "handshake", xmlns_component, handle_component_auth);
