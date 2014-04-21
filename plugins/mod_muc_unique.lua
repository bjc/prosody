-- XEP-0307: Unique Room Names for Multi-User Chat
local uuid_gen = require "util.uuid".generate;
module:add_feature "http://jabber.org/protocol/muc#unique"
module:hook("iq-get/host/http://jabber.org/protocol/muc#unique:unique", function()
	local origin, stanza = event.origin, event.stanza;
	origin.send(st.reply(stanza)
		:tag("unique", {xmlns = "http://jabber.org/protocol/muc#unique"})
		:text(uuid_gen()) -- FIXME Random UUIDs can theoretically have collisions
	);
	return true;
end,-1);
