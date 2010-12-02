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

local sha1 = require "util.hashes".sha1;
local st = require "util.stanza";

local log = module._log;

local main_session, send;

local function on_destroy(session, err)
	if main_session == session then
		main_session = nil;
		send = nil;
		session.on_destroy = nil;
	end
end

local function handle_stanza(event)
	local stanza = event.stanza;
	if send then
		stanza.attr.xmlns = nil;
		send(stanza);
	else
		log("warn", "Stanza being handled by default component; bouncing error for: %s", stanza:top_tag());
		if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
			event.origin.send(st.error_reply(stanza, "wait", "service-unavailable", "Component unavailable"));
		end
	end
	return true;
end

module:hook("iq/bare", handle_stanza, -1);
module:hook("message/bare", handle_stanza, -1);
module:hook("presence/bare", handle_stanza, -1);
module:hook("iq/full", handle_stanza, -1);
module:hook("message/full", handle_stanza, -1);
module:hook("presence/full", handle_stanza, -1);
module:hook("iq/host", handle_stanza, -1);
module:hook("message/host", handle_stanza, -1);
module:hook("presence/host", handle_stanza, -1);

--- Handle authentication attempts by components
function handle_component_auth(event)
	local session, stanza = event.origin, event.stanza;
	
	if session.type ~= "component" then return; end
	if main_session == session then return; end

	if (not session.host) or #stanza.tags > 0 then
		(session.log or log)("warn", "Invalid component handshake for host: %s", session.host);
		session:close("not-authorized");
		return true;
	end
	
	local secret = module:get_option("component_secret");
	if not secret then
		(session.log or log)("warn", "Component attempted to identify as %s, but component_secret is not set", session.host);
		session:close("not-authorized");
		return true;
	end
	
	local supplied_token = t_concat(stanza);
	local calculated_token = sha1(session.streamid..secret, true);
	if supplied_token:lower() ~= calculated_token:lower() then
		log("info", "Component authentication failed for %s", session.host);
		session:close{ condition = "not-authorized", text = "Given token does not match calculated token" };
		return true;
	end
	
	-- If component not already created for this host, create one now
	if not main_session then
		send = session.send;
		main_session = session;
		session.on_destroy = on_destroy;
		session.component_validate_from = module:get_option_boolean("validate_from_addresses") ~= false;
		log("info", "Component successfully authenticated: %s", session.host);
		session.send(st.stanza("handshake"));
	else -- TODO: Implement stanza distribution
		log("error", "Multiple components bound to the same address, first one wins: %s", session.host);
		session:close{ condition = "conflict", text = "Component already connected" };
	end
	
	return true;
end

module:hook("stanza/jabber:component:accept:handshake", handle_component_auth);
