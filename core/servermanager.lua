
local st = require "util.stanza";
local xmlns_stanzas ='urn:ietf:params:xml:ns:xmpp-stanzas';

local modulemanager = require "core.modulemanager";

-- Handle stanzas that were addressed to the server (whether they came from c2s, s2s, etc.)
function handle_stanza(origin, stanza)
	-- Use plugins
	if not modulemanager.handle_stanza(origin, stanza) then
		if stanza.name == "iq" then
			if stanza.attr.type ~= "result" and stanza.attr.type ~= "error" then
				origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
			end
		elseif stanza.name == "message" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		elseif stanza.name ~= "presence" then
			error("Unknown stanza");
		end
	end
end
