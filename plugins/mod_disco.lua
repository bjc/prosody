-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local discomanager_handle = require "core.discomanager".handle;

module:add_feature("http://jabber.org/protocol/disco#info");
module:add_feature("http://jabber.org/protocol/disco#items");

module:add_iq_handler({"c2s", "s2sin"}, "http://jabber.org/protocol/disco#info", function (session, stanza)
	session.send(discomanager_handle(stanza));
end);
module:add_iq_handler({"c2s", "s2sin"}, "http://jabber.org/protocol/disco#items", function (session, stanza)
	session.send(discomanager_handle(stanza));
end);
