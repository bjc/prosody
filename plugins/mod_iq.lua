-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "util.stanza";
local jid_split = require "util.jid".split;

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

	-- TODO fire post processing events
	if stanza.attr.type == "get" or stanza.attr.type == "set" then
		return module:fire_event("iq/bare/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name, data);
	else
		module:fire_event("iq-"..stanza.attr.type.."/bare/"..stanza.attr.id, data);
		return true;
	end
end);

module:hook("iq/self", function(data)
	-- IQ to bare JID recieved
	local origin, stanza = data.origin, data.stanza;

	if stanza.attr.type == "get" or stanza.attr.type == "set" then
		return module:fire_event("iq/self/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name, data);
	else
		module:fire_event("iq-"..stanza.attr.type.."/self/"..stanza.attr.id, data);
		return true;
	end
end);

module:hook("iq/host", function(data)
	-- IQ to a local host recieved
	local origin, stanza = data.origin, data.stanza;

	if stanza.attr.type == "get" or stanza.attr.type == "set" then
		return module:fire_event("iq/host/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name, data);
	else
		module:fire_event("iq-"..stanza.attr.type.."/host/"..stanza.attr.id, data);
		return true;
	end
end);
