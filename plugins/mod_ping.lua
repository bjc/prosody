-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza";

module:add_feature("urn:xmpp:ping");

module:add_iq_handler({"c2s", "s2sin"}, "urn:xmpp:ping",
	function(session, stanza)
		if stanza.attr.type == "get" then
			session.send(st.reply(stanza));
		end
	end);
