
local full_sessions = full_sessions;
local bare_sessions = bare_sessions;

local jid_bare = require "util.jid".bare;
local user_exists = require "core.usermanager".user_exists;

module:hook("message/full", function(data)
	-- message to full JID recieved
	local origin, stanza = data.origin, data.stanza;
	
	local session = full_sessions[stanza.attr.to];
	if session then
		-- TODO fire post processing event
		session.send(stanza);
		return true;
	else -- resource not online
		-- TODO fire event to send to bare JID
	end
end);

module:hook("message/bare", function(data)
	-- message to bare JID recieved
	local origin, stanza = data.origin, data.stanza;

	local sessions = bare_sessoins[stanza.attr.to];
	if sessions then sessions = sessions.sessions; end
	
	if sessions then
		-- some resources are online
		-- TODO find top resources willing to accept this message
		-- TODO then send them each the stanza
	else
		-- no resources are online
		-- TODO check if the user exists
		-- TODO if it doesn't, return an error reply
		-- TODO otherwise, apply the default privacy list
		-- TODO and store into offline storage
		-- TODO or maybe the offline store can apply privacy lists
	end
end);
