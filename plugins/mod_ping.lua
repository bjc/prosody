
local st = require "util.stanza";

require "core.discomanager".set("ping", "urn:xmpp:ping");

module:add_iq_handler({"c2s", "s2sin"}, "urn:xmpp:ping",
	function(session, stanza)
		if stanza.attr.type == "get" then
			session.send(st.reply(stanza));
		end
	end);
