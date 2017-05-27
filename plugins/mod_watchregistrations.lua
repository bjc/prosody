-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local host = module:get_host();
local jid_prep = require "util.jid".prep;

local registration_watchers = module:get_option_set("registration_watchers", module:get_option("admins", {})) / jid_prep;
local registration_from = module:get_option_string("registration_from", host);
local registration_notification = module:get_option_string("registration_notification", "User $username just registered on $host from $ip");

local st = require "util.stanza";

module:hook("user-registered", function (user)
	module:log("debug", "Notifying of new registration");
	local message = st.message{ type = "chat", from = registration_from }
		:tag("body")
			:text(registration_notification:gsub("%$(%w+)", function (v)
				return user[v] or user.session and user.session[v] or nil;
			end))
		:up();
	for jid in registration_watchers do
		module:log("debug", "Notifying %s", jid);
		message.attr.to = jid;
		module:send(message);
	end
end);
