local st = require "util.stanza"
local jid_split = require "util.jid".split;

local mod_pep = module:depends("pep");

module:hook("account-disco-info", function (event)
	event.reply:tag("feature", { var = "urn:ietf:params:xml:ns:vcard-4.0" }):up();
end);

module:hook("iq-get/bare/urn:ietf:params:xml:ns:vcard-4.0:vcard", function (event)
	local origin, stanza = event.origin, event.stanza;

	local pep_service = mod_pep.get_pep_service(jid_split(stanza.attr.to) or origin.username);
	local ok, id, item = pep_service:get_last_item("urn:xmpp:vcard4", stanza.attr.from);
	if ok and item then
		origin.send(st.reply(stanza):add_child(item.tags[1]));
	elseif id == "item-not-found" or not id then
		origin.send(st.error_reply(stanza, "cancel", "item-not-found"));
	elseif id == "forbidden" then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
	else
		origin.send(st.error_reply(stanza, "modify", "undefined-condition"));
	end
	return true;
end);

module:hook("iq-set/self/urn:ietf:params:xml:ns:vcard-4.0:vcard", function (event)
	local origin, stanza = event.origin, event.stanza;

	local vcard4 = st.stanza("item", { xmlns = "http://jabber.org/protocol/pubsub", id = "current" })
		:add_child(stanza.tags[1]);

	local pep_service = mod_pep.get_pep_service(origin.username);

	local ok, err = pep_service:publish("urn:xmpp:vcard4", origin.full_jid, "current", vcard4);
	if ok then
		origin.send(st.reply(stanza));
	elseif err == "forbidden" then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
	else
		origin.send(st.error_reply(stanza, "modify", "undefined-condition", err));
	end
	return true;
end);

