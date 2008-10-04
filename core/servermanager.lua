
local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;
local xmlns_stanzas ='urn:ietf:params:xml:ns:xmpp-stanzas';

require "modulemanager"

-- Handle stanzas that were addressed to the server (whether they came from c2s, s2s, etc.)
function handle_stanza(origin, stanza)
	-- Use plugins
	if not modulemanager.handle_stanza(origin, stanza) then
		if stanza.name == "iq" then
			local reply = st.reply(stanza);
			reply.attr.type = "error";
			reply:tag("error", { type = "cancel" })
				:tag("service-unavailable", { xmlns = xmlns_stanzas });
			send(origin, reply);
		end
	end
end
