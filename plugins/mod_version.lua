-- Prosody IM v0.3
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza";

local xmlns_version = "jabber:iq:version"

module:add_feature(xmlns_version);

local version = "the best operating system ever!";

if not require "core.configmanager".get("*", "core", "hide_os_type") then
	if os.getenv("WINDIR") then
		version = "Windows";
	else
		local uname = io.popen("uname");
		if uname then
			version = uname:read("*a");
		else
			version = "an OS";
		end
	end
end

version = version:match("^%s*(.-)%s*$") or version;

module:add_iq_handler({"c2s", "s2sin"}, xmlns_version, function(session, stanza)
	if stanza.attr.type == "get" then
		session.send(st.reply(stanza):query(xmlns_version)
			:tag("name"):text("Prosody"):up()
			:tag("version"):text("0.3"):up()
			:tag("os"):text(version));
	end
end);
