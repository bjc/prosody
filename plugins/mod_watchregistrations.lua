-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local host = module:get_host();

local registration_watchers = module:get_option("registration_watchers")
	or module:get_option("admins") or {};

local registration_alert = module:get_option("registration_notification") or "User $username just registered on $host from $ip";

local st = require "util.stanza";

module:hook("user-registered",
	function (user)
		module:log("debug", "Notifying of new registration");
		local message = st.message{ type = "chat", from = host }
					:tag("body")
					:text(registration_alert:gsub("%$(%w+)",
						function (v) return user[v] or user.session and user.session[v] or nil; end));
		
		for _, jid in ipairs(registration_watchers) do
			module:log("debug", "Notifying %s", jid);
			message.attr.to = jid;
			core_route_stanza(hosts[host], message);
		end
	end);
