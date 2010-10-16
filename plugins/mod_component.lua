-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

if module:get_host_type() ~= "component" then
	error("Don't load mod_component manually, it should be for a component, please see http://prosody.im/doc/components", 0);
end

local hosts = _G.hosts;

local t_concat = table.concat;

local config = require "core.configmanager";
local cm_register_component = require "core.componentmanager".register_component;
local cm_deregister_component = require "core.componentmanager".deregister_component;
local sha1 = require "util.hashes".sha1;
local st = require "util.stanza";

local log = module._log;

--- Handle authentication attempts by components
function handle_component_auth(event)
	local session, stanza = event.origin, event.stanza;
	
	if session.type ~= "component" then return; end

	log("info", "Handling component auth");
	if (not session.host) or #stanza.tags > 0 then
		(session.log or log)("warn", "Component handshake invalid");
		session:close("not-authorized");
		return true;
	end
	
	local secret = config.get(session.host, "core", "component_secret");
	if not secret then
		(session.log or log)("warn", "Component attempted to identify as %s, but component_secret is not set", session.host);
		session:close("not-authorized");
		return true;
	end
	
	local supplied_token = t_concat(stanza);
	local calculated_token = sha1(session.streamid..secret, true);
	if supplied_token:lower() ~= calculated_token:lower() then
		log("info", "Component for %s authentication failed", session.host);
		session:close{ condition = "not-authorized", text = "Given token does not match calculated token" };
		return true;
	end
	
	
	-- Authenticated now
	log("info", "Component authenticated: %s", session.host);
	
	session.component_validate_from = module:get_option_boolean("validate_from_addresses") ~= false;
	
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
	return true;
end

module:hook("stanza/jabber:component:accept:handshake", handle_component_auth);
