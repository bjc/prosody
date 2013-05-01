-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "util.stanza";

local full_sessions = prosody.full_sessions;

if module:get_host_type() == "local" then
	module:hook("iq/full", function(data)
		-- IQ to full JID recieved
		local origin, stanza = data.origin, data.stanza;

		local session = full_sessions[stanza.attr.to];
		if not (session and session.send(stanza)) then
			if stanza.attr.type == "get" or stanza.attr.type == "set" then
				origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
			end
		end
		return true;
	end);
end

module:hook("iq/bare", function(data)
	-- IQ to bare JID recieved
	local stanza = data.stanza;
	local type = stanza.attr.type;

	-- TODO fire post processing events
	if type == "get" or type == "set" then
		local child = stanza.tags[1];
		local xmlns = child.attr.xmlns or "jabber:client";
		local ret = module:fire_event("iq/bare/"..xmlns..":"..child.name, data);
		if ret ~= nil then return ret; end
		return module:fire_event("iq-"..type.."/bare/"..xmlns..":"..child.name, data);
	else
		return module:fire_event("iq-"..type.."/bare/"..stanza.attr.id, data);
	end
end);

module:hook("iq/self", function(data)
	-- IQ to self JID recieved
	local stanza = data.stanza;
	local type = stanza.attr.type;

	if type == "get" or type == "set" then
		local child = stanza.tags[1];
		local xmlns = child.attr.xmlns or "jabber:client";
		local ret = module:fire_event("iq/self/"..xmlns..":"..child.name, data);
		if ret ~= nil then return ret; end
		return module:fire_event("iq-"..type.."/self/"..xmlns..":"..child.name, data);
	else
		return module:fire_event("iq-"..type.."/self/"..stanza.attr.id, data);
	end
end);

module:hook("iq/host", function(data)
	-- IQ to a local host recieved
	local stanza = data.stanza;
	local type = stanza.attr.type;

	if type == "get" or type == "set" then
		local child = stanza.tags[1];
		local xmlns = child.attr.xmlns or "jabber:client";
		local ret = module:fire_event("iq/host/"..xmlns..":"..child.name, data);
		if ret ~= nil then return ret; end
		return module:fire_event("iq-"..type.."/host/"..xmlns..":"..child.name, data);
	else
		return module:fire_event("iq-"..type.."/host/"..stanza.attr.id, data);
	end
end);
