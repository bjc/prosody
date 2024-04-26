-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local usermanager = require "prosody.core.usermanager";
local id = require "prosody.util.id";
local jid = require "prosody.util.jid";
local st = require "prosody.util.stanza";

local hosts = prosody.hosts;

function send_to_online(message, host)
	host = host or module.host;
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

function send_to_all(message, host)
	host = host or module.host;
	local c = 0;
	for username in usermanager.users(host) do
		message.attr.to = username.."@"..host;
		module:send(st.clone(message));
		c = c + 1;
	end
	return c;
end

function send_to_role(message, role, host)
	host = host or module.host;
	local c = 0;
	for _, recipient_jid in ipairs(usermanager.get_jids_with_role(role, host)) do
		message.attr.to = recipient_jid;
		module:send(st.clone(message));
		c = c + 1;
	end
	return c;
end

module:default_permission("prosody:admin", ":send-announcement");

-- Old <message>-based jabberd-style announcement sending
function handle_announcement(event)
	local stanza = event.stanza;
	-- luacheck: ignore 211/node
	local node, host, resource = jid.split(stanza.attr.to);

	if resource ~= "announce/online" then
		return; -- Not an announcement
	end

	if not module:may(":send-announcement", event) then
		-- Not allowed!
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
local dataforms_new = require "prosody.util.dataforms".new;
local announce_layout = dataforms_new{
	title = "Making an Announcement";
	instructions = "Fill out this form to make an announcement to all\nactive users of this service.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "subject", type = "text-single", label = "Subject" };
	{ name = "announcement", type = "text-multi", required = true, label = "Announcement" };
};

function announce_handler(_, data, state)
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = announce_layout:data(data.form);

		module:log("info", "Sending server announcement to all online users");
		local message = st.message({type = "headline"}, fields.announcement):up();
		if fields.subject and fields.subject ~= "" then
			message:text_tag("subject", fields.subject);
		end

		local count = send_to_online(message, data.to);

		module:log("info", "Announcement sent to %d online users", count);
		return { status = "completed", info = ("Announcement sent to %d online users"):format(count) };
	else
		return { status = "executing", actions = {"next", "complete", default = "complete"}, form = announce_layout }, "executing";
	end
end

module:depends "adhoc";
local adhoc_new = module:require "adhoc".new;
local announce_desc = adhoc_new("Send Announcement to Online Users", "http://jabber.org/protocol/admin#announce", announce_handler, "admin");
module:provides("adhoc", announce_desc);

module:add_item("shell-command", {
	section = "announce";
	section_desc = "Broadcast announcements to users";
	name = "all";
	desc = "Send announcement to all users on the host";
	args = {
		{ name = "host", type = "string" };
		{ name = "text", type = "string" };
	};
	host_selector = "host";
	handler = function(self, host, text) --luacheck: ignore 212/self
		local msg = st.message({ from = host, id = id.short() })
			:text_tag("body", text);
		local count = send_to_all(msg, host);
		return true, ("Announcement sent to %d users"):format(count);
	end;
});

module:add_item("shell-command", {
	section = "announce";
	section_desc = "Broadcast announcements to users";
	name = "online";
	desc = "Send announcement to all online users on the host";
	args = {
		{ name = "host", type = "string" };
		{ name = "text", type = "string" };
	};
	host_selector = "host";
	handler = function(self, host, text) --luacheck: ignore 212/self
		local msg = st.message({ from = host, id = id.short(), type = "headline" })
			:text_tag("body", text);
		local count = send_to_online(msg, host);
		return true, ("Announcement sent to %d users"):format(count);
	end;
});

module:add_item("shell-command", {
	section = "announce";
	section_desc = "Broadcast announcements to users";
	name = "role";
	desc = "Send announcement to users with a specific role on the host";
	args = {
		{ name = "host", type = "string" };
		{ name = "role", type = "string" };
		{ name = "text", type = "string" };
	};
	host_selector = "host";
	handler = function(self, host, role, text) --luacheck: ignore 212/self
		local msg = st.message({ from = host, id = id.short() })
			:text_tag("body", text);
		local count = send_to_role(msg, role, host);
		return true, ("Announcement sent to %d users"):format(count);
	end;
});
