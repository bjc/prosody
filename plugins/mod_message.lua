
local full_sessions = full_sessions;
local bare_sessions = bare_sessions;

local jid_bare = require "util.jid".bare;
local user_exists = require "core.usermanager".user_exists;

local function process_to_bare(bare, origin, stanza)
	local sessions = bare_sessions[bare];
	
	local t = stanza.attr.type;
	if t == "error" then return true; end
	if t == "groupchat" then
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		return true;
	end

	if sessions then
		-- some resources are connected
		sessions = sessions.sessions;
		
		if t == "headline" then
			for _, session in pairs(sessions) do
				if session.presence and session.priority >= 0 then
					session.send(stanza);
				end
			end
			return true;
		end
		-- TODO find top resources willing to accept this message
		-- TODO then send them each the stanza
		return;
	end
	-- no resources are online
	if t == "headline" then return true; end -- current policy is to discard headlines
	-- chat or normal message
	-- TODO check if the user exists
	-- TODO if it doesn't, return an error reply
	-- TODO otherwise, apply the default privacy list
	-- TODO and store into offline storage
	-- TODO or maybe the offline store can apply privacy lists
end

module:hook("message/full", function(data)
	-- message to full JID recieved
	local origin, stanza = data.origin, data.stanza;
	
	local session = full_sessions[stanza.attr.to];
	if session then
		-- TODO fire post processing event
		session.send(stanza);
		return true;
	else -- resource not online
		return process_to_bare(jid_bare(stanza.attr.to), origin, stanza);
	end
end);

module:hook("message/bare", function(data)
	-- message to bare JID recieved
	local origin, stanza = data.origin, data.stanza;

	return process_to_bare(stanza.attr.to or (origin.username..'@'..origin.host), origin, stanza);
end);
