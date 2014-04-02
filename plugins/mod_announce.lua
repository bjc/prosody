-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st, jid = require "util.stanza", require "util.jid";

local hosts = prosody.hosts;
local is_admin = require "core.usermanager".is_admin;

function send_to_online(message, host)
	local sessions;
	if host then
		sessions = { [host] = hosts[host] };
	else
		sessions = hosts;
	end

	local c = 0;
	for hostname, host_session in pairs(sessions) do
		if host_session.sessions then
			message.attr.from = hostname;
			for username in pairs(host_session.sessions) do
				c = c + 1;
				message.attr.to = username.."@"..hostname;
				module:send(message);
			end
		end
	end

	return c;
end


-- Old <message>-based jabberd-style announcement sending
function handle_announcement(event)
	local origin, stanza = event.origin, event.stanza;
	local node, host, resource = jid.split(stanza.attr.to);

	if resource ~= "announce/online" then
		return; -- Not an announcement
	end

	if not is_admin(stanza.attr.from) then
		-- Not an admin? Not allowed!
		module:log("warn", "Non-admin '%s' tried to send server announcement", stanza.attr.from);
		return;
	end

	module:log("info", "Sending server announcement to all online users");
	local message = st.clone(stanza);
	message.attr.type = "headline";
	message.attr.from = host;

	local c = send_to_online(message, host);
	module:log("info", "Announcement sent to %d online users", c);
	return true;
end
module:hook("message/host", handle_announcement);

-- Ad-hoc command (XEP-0133)
local dataforms_new = require "util.dataforms".new;
local announce_layout = dataforms_new{
	title = "Making an Announcement";
	instructions = "Fill out this form to make an announcement to all\nactive users of this service.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "subject", type = "text-single", label = "Subject" };
	{ name = "announcement", type = "text-multi", required = true, label = "Announcement" };
};

function announce_handler(self, data, state)
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = announce_layout:data(data.form);

		module:log("info", "Sending server announcement to all online users");
		local message = st.message({type = "headline"}, fields.announcement):up()
			:tag("subject"):text(fields.subject or "Announcement");

		local count = send_to_online(message, data.to);

		module:log("info", "Announcement sent to %d online users", count);
		return { status = "completed", info = ("Announcement sent to %d online users"):format(count) };
	else
		return { status = "executing", actions = {"next", "complete", default = "complete"}, form = announce_layout }, "executing";
	end

	return true;
end

local adhoc_new = module:require "adhoc".new;
local announce_desc = adhoc_new("Send Announcement to Online Users", "http://jabber.org/protocol/admin#announce", announce_handler, "admin");
module:provides("adhoc", announce_desc);

