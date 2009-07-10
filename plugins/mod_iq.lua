-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "util.stanza";
local jid_split = require "util.jid".split;
local user_exists = require "core.usermanager".user_exists;

local full_sessions = full_sessions;
local bare_sessions = bare_sessions;

module:hook("iq/full", function(data)
	-- IQ to full JID recieved
	local origin, stanza = data.origin, data.stanza;

	local session = full_sessions[stanza.attr.to];
	if session then
		-- TODO fire post processing event
		session.send(stanza);
	else -- resource not online
		if stanza.attr.type == "get" or stanza.attr.type == "set" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	end
	return true;
end);

module:hook("iq/bare", function(data)
	-- IQ to bare JID recieved
	local origin, stanza = data.origin, data.stanza;

	local to = stanza.attr.to;
	if to and not bare_sessions[to] then -- quick check for account existance
		local node, host = jid_split(to);
		if not user_exists(node, host) then -- full check for account existance
			if stanza.attr.type == "get" or stanza.attr.type == "set" then
				origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
			end
			return true;
		end
	end
	-- TODO fire post processing events
	if stanza.attr.type == "get" or stanza.attr.type == "set" then
		return module:fire_event("iq/bare/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name, data);
	else
		module:fire_event("iq/bare/"..stanza.attr.id, data);
		return true;
	end
end);

module:hook("iq/host", function(data)
	-- IQ to a local host recieved
	local origin, stanza = data.origin, data.stanza;

	if stanza.attr.type == "get" or stanza.attr.type == "set" then
		return module:fire_event("iq/host/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name, data);
	else
		module:fire_event("iq/host/"..stanza.attr.id, data);
		return true;
	end
end);
