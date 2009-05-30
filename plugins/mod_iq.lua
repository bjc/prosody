
module:hook("iq/full", function(data)
	-- IQ to full JID recieved
	local origin, stanza = data.origin, data.stanza;

	local session = full_sessions[stanza.attr.to];
	if session then
		-- TODO fire post processing event
		session.send(stanza);
		return true;
	else -- resource not online
		-- TODO error reply
	end
end);

module:hook("iq/bare", function(data)
	-- IQ to bare JID recieved
	local origin, stanza = data.origin, data.stanza;

	-- TODO if not user exists, return an error
	-- TODO fire post processing events
	-- TODO fire event with the xmlns:tag of the child, or with the id of errors and results
end);

module:hook("iq/host", function(data)
	-- IQ to a local host recieved
	local origin, stanza = data.origin, data.stanza;

	-- TODO fire event with the xmlns:tag of the child, or with the id of errors and results
end);
