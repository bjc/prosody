-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

module:add_feature("jabber:iq:version");

local version = "the best operating system ever!";

if not module:get_option("hide_os_type") then
	if os.getenv("WINDIR") then
		version = "Windows";
	else
		local uname = io.popen(module:get_option("os_version_command") or "uname");
		if uname then
			version = uname:read("*a");
		else
			version = "an OS";
		end
	end
end

version = version:match("^%s*(.-)%s*$") or version;

local query = st.stanza("query", {xmlns = "jabber:iq:version"})
	:tag("name"):text("Prosody"):up()
	:tag("version"):text(prosody.version):up()
	:tag("os"):text(version);

module:hook("iq/host/jabber:iq:version:query", function(event)
	local stanza = event.stanza;
	if stanza.attr.type == "get" and stanza.attr.to == module.host then
		event.origin.send(st.reply(stanza):add_child(query));
		return true;
	end
end);
