-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local host = module:get_host();
local welcome_text = module:get_option_string("welcome_message", "Hello $username, welcome to the $host IM server!");

local st = require "prosody.util.stanza";

module:hook("user-registered",
	function (user)
		local welcome_stanza =
			st.message({ to = user.username.."@"..user.host, from = host },
				welcome_text:gsub("$(%w+)", user));
		module:send(welcome_stanza);
		module:log("debug", "Welcomed user %s@%s", user.username, user.host);
	end);
