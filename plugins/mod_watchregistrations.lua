-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local host = module:get_host();

local config = require "core.configmanager";

local registration_watchers = config.get(host, "core", "registration_watchers") 
	or config.get(host, "core", "admins") or {};

local registration_alert = config.get(host, "core", "registration_notification") or "User $username just registered on $host from $ip";

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
