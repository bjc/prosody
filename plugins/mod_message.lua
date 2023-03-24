-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local full_sessions = prosody.full_sessions;
local bare_sessions = prosody.bare_sessions;

local st = require "prosody.util.stanza";
local jid_bare = require "prosody.util.jid".bare;
local jid_split = require "prosody.util.jid".split;
local user_exists = require "prosody.core.usermanager".user_exists;

local function process_to_bare(bare, origin, stanza)
	local user = bare_sessions[bare];

	local t = stanza.attr.type;
	if t == "error" then
		return true; -- discard
	elseif t == "groupchat" then
		local node, host = jid_split(bare);
		if user_exists(node, host) then
			if module:fire_event("message/bare/groupchat", {
				origin = origin, stanza = stanza;
			}) then
				return true;
			end
		end

		origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	elseif t == "headline" then
		if user and stanza.attr.to == bare then
			for _, session in pairs(user.sessions) do
				if session.presence and session.priority >= 0 then
					session.send(stanza);
				end
			end
		end  -- current policy is to discard headlines if no recipient is available
	else -- chat or normal message
		if user then -- some resources are connected
			local recipients = user.top_resources;
			if recipients then
				local sent;
				for i=1,#recipients do
					sent = recipients[i].send(stanza) or sent;
				end
				if sent then
					return true;
				end
			end
		end
		-- no resources are online
		local node, host = jid_split(bare);
		local ok
		if user_exists(node, host) then
			ok = module:fire_event('message/offline/handle', {
				username = node, -- username of the recipient of the offline message
				origin = origin, -- the sender
				stanza = stanza,
			});
		end

		if not ok then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	end
	return true;
end

module:hook("message/full", function(data)
	-- message to full JID received
	local origin, stanza = data.origin, data.stanza;

	local session = full_sessions[stanza.attr.to];
	if session and session.send(stanza) then
		return true;
	else -- resource not online
		return process_to_bare(jid_bare(stanza.attr.to), origin, stanza);
	end
end, -1);

module:hook("message/bare", function(data)
	-- message to bare JID received
	local origin, stanza = data.origin, data.stanza;

	return process_to_bare(stanza.attr.to or (origin.username..'@'..origin.host), origin, stanza);
end, -1);
