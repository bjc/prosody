
local discomanager_handle = require "core.discomanager".handle;

require "core.discomanager".set("disco", "http://jabber.org/protocol/disco#info");
require "core.discomanager".set("disco", "http://jabber.org/protocol/disco#items");

add_iq_handler({"c2s", "s2sin"}, "http://jabber.org/protocol/disco#info", function (session, stanza)
	session.send(discomanager_handle(stanza));
end);
add_iq_handler({"c2s", "s2sin"}, "http://jabber.org/protocol/disco#items", function (session, stanza)
	session.send(discomanager_handle(stanza));
end);
