-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2010 Jeff Mitchell
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local host = module:get_host();
local motd_text = module:get_option_string("motd_text");
local motd_jid = module:get_option_string("motd_jid", host);

if not motd_text then return; end

local st = require "prosody.util.stanza";

motd_text = motd_text:gsub("^%s*(.-)%s*$", "%1"):gsub("\n[ \t]+", "\n"); -- Strip indentation from the config

module:hook("presence/initial", function (event)
	local session = event.origin;
	local motd_stanza =
		st.message({ to = session.full_jid, from = motd_jid })
			:tag("body"):text(motd_text);
	module:send(motd_stanza);
	module:log("debug", "MOTD send to user %s", session.full_jid);
end, 1);
