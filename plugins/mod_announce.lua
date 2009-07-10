-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st, jid, set = require "util.stanza", require "util.jid", require "util.set";

local is_admin = require "core.usermanager".is_admin;
local admins = set.new(config.get(module:get_host(), "core", "admins"));

function handle_announcement(data)
	local origin, stanza = data.origin, data.stanza;
	local host, resource = select(2, jid.split(stanza.attr.to));
	
	if resource ~= "announce/online" then
		return; -- Not an announcement
	end
	
	if not is_admin(stanza.attr.from) then
		-- Not an admin? Not allowed!
		module:log("warn", "Non-admin %s tried to send server announcement", tostring(jid.bare(stanza.attr.from)));
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		return;
	end
	
	module:log("info", "Sending server announcement to all online users");
	local host_session = hosts[host];
	local message = st.clone(stanza);
	message.attr.type = "headline";
	message.attr.from = host;
	
	local c = 0;
	for user in pairs(host_session.sessions) do
		c = c + 1;
		message.attr.to = user.."@"..host;
		core_post_stanza(host_session, message);
	end
	
	module:log("info", "Announcement sent to %d online users", c);
	return true;
end

module:hook("message/host", handle_announcement);
