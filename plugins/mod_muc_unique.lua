-- XEP-0307: Unique Room Names for Multi-User Chat
local st = require "prosody.util.stanza";
local unique_name = require "prosody.util.id".medium;
module:add_feature "http://jabber.org/protocol/muc#unique"
module:hook("iq-get/host/http://jabber.org/protocol/muc#unique:unique", function(event)
	local origin, stanza = event.origin, event.stanza;
	origin.send(st.reply(stanza)
		:tag("unique", {xmlns = "http://jabber.org/protocol/muc#unique"})
		:text(unique_name():lower())
	);
	return true;
end,-1);
