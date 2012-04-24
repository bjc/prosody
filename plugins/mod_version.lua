-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

module:add_feature("jabber:iq:version");

local version;

local query = st.stanza("query", {xmlns = "jabber:iq:version"})
	:tag("name"):text("Prosody"):up()
	:tag("version"):text(prosody.version):up();

if not module:get_option("hide_os_type") then
	if os.getenv("WINDIR") then
		version = "Windows";
	else
		local os_version_command = module:get_option("os_version_command");
		local ok, pposix = pcall(require, "util.pposix");
		if not os_version_command and (ok and pposix and pposix.uname) then
			version = pposix.uname().sysname;
		end
		if not version then
			local uname = io.popen(os_version_command or "uname");
			if uname then
				version = uname:read("*a");
			end
			uname:close();
		end
	end
	if version then
		version = version:match("^%s*(.-)%s*$") or version;
		query:tag("os"):text(version):up();
	end
end

module:hook("iq/host/jabber:iq:version:query", function(event)
	local stanza = event.stanza;
	if stanza.attr.type == "get" and stanza.attr.to == module.host then
		event.origin.send(st.reply(stanza):add_child(query));
		return true;
	end
end);
