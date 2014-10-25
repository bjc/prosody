-- Prosody IM
-- Copyright (C) 2009-2010 Matthew Wild
-- Copyright (C) 2009-2010 Waqas Hussain
-- Copyright (C) 2014 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- This module implements XEP-0191: Blocking Command
--

local user_exists = require"core.usermanager".user_exists;
local is_contact_subscribed = require"core.rostermanager".is_contact_subscribed;
local st = require"util.stanza";
local st_error_reply = st.error_reply;
local jid_prep, jid_split = import("jid", "prep", "split");

local host = module.host;
local storage = module:open_store();
local sessions = prosody.hosts[host].sessions;

-- Cache of blocklists used since module was loaded
local cache = {};
if module:get_option_boolean("blocklist_weak_cache") then
	-- Lower memory usage, more IO and latency
	setmetatable(cache, { __mode = "v" });
end

local null_blocklist = {};

module:add_feature("urn:xmpp:blocking");

local function set_blocklist(username, blocklist)
	local ok, err = storage:set(username, blocklist);
	if not ok then
		return ok, err;
	end
	-- Successful save, update the cache
	cache[username] = blocklist;
	return true;
end

-- Migrates from the old mod_privacy storage
local function migrate_privacy_list(username)
	local migrated_data = { [false] = "not empty" };
	local legacy_data = module:open_store("privacy"):get(username);
	if legacy_data and legacy_data.lists and legacy_data.default then
		legacy_data = legacy_data.lists[legacy_data.default];
		legacy_data = legacy_data and legacy_data.items;
	else
		return migrated_data;
	end
	if legacy_data then
		module:log("info", "Migrating blocklist from mod_privacy storage for user '%s'", username);
		local item, jid;
		for i = 1, #legacy_data do
			item = legacy_data[i];
			if item.type == "jid" and item.action == "deny" then
				jid = jid_prep(item.value);
				if not jid then
					module:log("warn", "Invalid JID in privacy store for user '%s' not migrated: %s", username, tostring(item.value));
				else
					migrated_data[jid] = true;
				end
			end
		end
	end
	set_blocklist(username, migrated_data);
	return migrated_data;
end

local function get_blocklist(username)
	local blocklist = cache[username];
	if not blocklist then
		if not user_exists(username, host) then
			return null_blocklist;
		end
		blocklist = storage:get(username);
		if not blocklist then
			blocklist = migrate_privacy_list(username);
		end
		cache[username] = blocklist;
	end
	return blocklist;
end

module:hook("iq-get/self/urn:xmpp:blocking:blocklist", function (event)
	local origin, stanza = event.origin, event.stanza;
	local username = origin.username;
	local reply = st.reply(stanza):tag("blocklist", { xmlns = "urn:xmpp:blocking" });
	local blocklist = get_blocklist(username);
	for jid in pairs(blocklist) do
		if jid then
			reply:tag("item", { jid = jid }):up();
		end
	end
	origin.interested_blocklist = true; -- Gets notified about changes
	return origin.send(reply);
end);

-- Add or remove some jid(s) from the blocklist
-- We want this to be atomic and not do a partial update
local function edit_blocklist(event)
	local origin, stanza = event.origin, event.stanza;
	local username = origin.username;
	local action = stanza.tags[1];
	local new = {};

	local jid;
	for item in action:childtags("item") do
		jid = jid_prep(item.attr.jid);
		if not jid then
			return origin.send(st_error_reply(stanza, "modify", "jid-malformed"));
		end
		item.attr.jid = jid; -- echo back prepped
		new[jid] = is_contact_subscribed(username, host, jid) or false;
	end

	local mode = action.name == "block" or nil;

	if mode and not next(new) then
		-- <block/> element does not contain at least one <item/> child element
		return origin.send(st_error_reply(stanza, "modify", "bad-request"));
	end

	local blocklist = get_blocklist(username);

	local new_blocklist = {};

	if mode or next(new) then
		for jid in pairs(blocklist) do
			new_blocklist[jid] = true;
		end
		for jid in pairs(new) do
			new_blocklist[jid] = mode;
		end
		-- else empty the blocklist
	end
	new_blocklist[false] = "not empty"; -- In order to avoid doing the migration thing twice

	local ok, err = set_blocklist(username, new_blocklist);
	if ok then
		origin.send(st.reply(stanza));
	else
		return origin.send(st_error_reply(stanza, "wait", "internal-server-error", err));
	end

	if mode then
		for jid, in_roster in pairs(new) do
			if not blocklist[jid] and in_roster and sessions[username] then
				for _, session in pairs(sessions[username].sessions) do
					module:send(st.presence({ type = "unavailable", to = jid, from = session.full_jid }));
				end
			end
		end
	end
	if sessions[username] then
		local blocklist_push = st.iq({ type = "set", id = "blocklist-push" })
			:add_child(action); -- I am lazy

		for _, session in pairs(sessions[username].sessions) do
			if session.interested_blocklist then
				blocklist_push.attr.to = session.full_jid;
				session.send(blocklist_push);
			end
		end
	end

	return true;
end

module:hook("iq-set/self/urn:xmpp:blocking:block", edit_blocklist);
module:hook("iq-set/self/urn:xmpp:blocking:unblock", edit_blocklist);

-- Cache invalidation, solved!
module:hook_global("user-deleted", function (event)
	if event.host == host then
		cache[event.username] = nil;
	end
end);

-- Buggy clients
module:hook("iq-error/self/blocklist-push", function (event)
	local type, condition, text = event.stanza:get_error();
	(event.origin.log or module._log)("warn", "Client returned an error in response to notification from mod_%s: %s%s%s", module.name, condition, text and ": " or "", text or "");
	return true;
end);

local function is_blocked(user, jid)
	local blocklist = cache[user] or get_blocklist(user);
	if blocklist[jid] then return true; end
	local node, host = jid_split(jid);
	return blocklist[host] or node and blocklist[node..'@'..host];
end

-- Event handlers for bouncing or dropping stanzas
local function drop_stanza(event)
	local stanza = event.stanza;
	local attr = stanza.attr;
	local to, from = attr.to, attr.from;
	to = to and jid_split(to);
	if to and from then
		return is_blocked(to, from);
	end
end

local function bounce_stanza(event)
	local origin, stanza = event.origin, event.stanza;
	if drop_stanza(event) then
		return origin.send(st_error_reply(stanza, "cancel", "service-unavailable"));
	end
end

local function bounce_iq(event)
	local type = event.stanza.attr.type;
	if type == "set" or type == "get" then
		return bounce_stanza(event);
	end
	return drop_stanza(event); -- result or error
end

local function bounce_message(event)
	local type = event.stanza.attr.type;
	if type == "chat" or not type or type == "normal" then
		return bounce_stanza(event);
	end
	return drop_stanza(event); -- drop headlines, groupchats etc
end

local function drop_outgoing(event)
	local origin, stanza = event.origin, event.stanza;
	local username = origin.username or jid_split(stanza.attr.from);
	if not username then return end
	local to = stanza.attr.to;
	if to then return is_blocked(username, to); end
	-- nil 'to' means a self event, don't bock those
end

local function bounce_outgoing(event)
	local origin, stanza = event.origin, event.stanza;
	local type = stanza.attr.type;
	if type == "error" or stanza.name == "iq" and type == "result" then
		return drop_outgoing(event);
	end
	if drop_outgoing(event) then
		return origin.send(st_error_reply(stanza, "cancel", "not-acceptable", "You have blocked this JID")
			:tag("blocked", { xmlns = "urn:xmpp:blocking:errors" }));
	end
end

-- Hook all the events!
local prio_in, prio_out = 100, 100;
module:hook("presence/bare", drop_stanza, prio_in);
module:hook("presence/full", drop_stanza, prio_in);

module:hook("message/bare", bounce_message, prio_in);
module:hook("message/full", bounce_message, prio_in);

module:hook("iq/bare", bounce_iq, prio_in);
module:hook("iq/full", bounce_iq, prio_in);

module:hook("pre-message/bare", bounce_outgoing, prio_out);
module:hook("pre-message/full", bounce_outgoing, prio_out);
module:hook("pre-message/host", bounce_outgoing, prio_out);

module:hook("pre-presence/bare", drop_outgoing, prio_out);
module:hook("pre-presence/full", drop_outgoing, prio_out);
module:hook("pre-presence/host", drop_outgoing, prio_out);

module:hook("pre-iq/bare", bounce_outgoing, prio_out);
module:hook("pre-iq/full", bounce_outgoing, prio_out);
module:hook("pre-iq/host", bounce_outgoing, prio_out);

