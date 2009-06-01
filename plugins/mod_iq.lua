
local st = require "util.stanza";

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

	-- TODO if not user exists, return an error
	-- TODO fire post processing events
	if #stanza.tags == 1 then
		return module:fire_event("iq/bare/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name, data);
	else
		return true; -- TODO do something with results and errors
	end
end);

module:hook("iq/host", function(data)
	-- IQ to a local host recieved
	local origin, stanza = data.origin, data.stanza;

	if #stanza.tags == 1 then
		return module:fire_event("iq/host/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name, data);
	else
		return true; -- TODO do something with results and errors
	end
end);
