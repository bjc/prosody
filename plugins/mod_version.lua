-- Prosody IM v0.2
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza";

local xmlns_version = "jabber:iq:version"

module:add_feature(xmlns_version);

module:add_iq_handler({"c2s", "s2sin"}, xmlns_version, function(session, stanza)
	if stanza.attr.type == "get" then
		session.send(st.reply(stanza):query(xmlns_version)
			:tag("name"):text("Prosody"):up()
			:tag("version"):text("0.2"):up()
			:tag("os"):text("the best operating system ever!"));
	end
end);
