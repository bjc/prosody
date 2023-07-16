-- Prosody IM
-- Copyright (C) 2009-2010 Matthew Wild
-- Copyright (C) 2009-2010 Waqas Hussain
-- Copyright (C) 2014-2015 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- This module implements XEP-0191: Blocking Command
--

local user_exists = require"prosody.core.usermanager".user_exists;
local rostermanager = require"prosody.core.rostermanager";
local is_contact_subscribed = rostermanager.is_contact_subscribed;
local is_contact_pending_in = rostermanager.is_contact_pending_in;
local load_roster = rostermanager.load_roster;
local save_roster = rostermanager.save_roster;
local st = require"prosody.util.stanza";
local st_error_reply = st.error_reply;
local jid_prep = require"prosody.util.jid".prep;
local jid_split = require"prosody.util.jid".split;

local storage = module:open_store();
local sessions = prosody.hosts[module.host].sessions;
local full_sessions = prosody.full_sessions;

-- First level cache of blocklists by username.
-- Weak table so may randomly expire at any time.
local cache = setmetatable({}, { __mode = "v" });

-- Second level of caching, keeps a fixed number of items, also anchors
-- items in the above cache.
--
-- The size of this affects how often we will need to load a blocklist from
-- disk, which we want to avoid during routing. On the other hand, we don't
-- want to use too much memory either, so this can be tuned by advanced
-- users. TODO use science to figure out a better default, 64 is just a guess.
local cache_size = module:get_option_integer("blocklist_cache_size", 64, 1);
local cache2 = require"prosody.util.cache".new(cache_size);

local null_blocklist = {};

module:add_feature("urn:xmpp:blocking");

local function set_blocklist(username, blocklist)
	local ok, err = storage:set(username, blocklist);
	if not ok then
		return ok, err;
	end
	-- Successful save, update the cache
	cache2:set(username, blocklist);
	cache[username] = blocklist;
	return true;
end

-- Migrates from the old mod_privacy storage
-- TODO mod_privacy was removed in 0.10.0, this should be phased out
local function migrate_privacy_list(username)
	local legacy_data = module:open_store("privacy"):get(username);
	if not legacy_data or not legacy_data.lists or not legacy_data.default then return; end
	local default_list = legacy_data.lists[legacy_data.default];
	if not default_list or not default_list.items then return; end

	local migrated_data = { [false] = { created = os.time(); migrated = "privacy" }};

	module:log("info", "Migrating blocklist from mod_privacy storage for user '%s'", username);
	for _, item in ipairs(default_list.items) do
		if item.type == "jid" and item.action == "deny" then
			local jid = jid_prep(item.value);
			if not jid then
				module:log("warn", "Invalid JID in privacy store for user '%s' not migrated: %s", username, item.value);
			else
				migrated_data[jid] = true;
			end
		end
	end
	set_blocklist(username, migrated_data);
	return migrated_data;
end

if not module:get_option_boolean("migrate_legacy_blocking", true) then
	migrate_privacy_list = function (username)
		module:log("debug", "Migrating from mod_privacy disabled, user '%s' will start with a fresh blocklist", username);
		return nil;
	end
end

local function get_blocklist(username)
	local blocklist = cache2:get(username);
	if not blocklist then
		if not user_exists(username, module.host) then
			return null_blocklist;
		end
		blocklist = storage:get(username);
		if not blocklist then
			blocklist = migrate_privacy_list(username);
		end
		if not blocklist then
			blocklist = { [false] = { created = os.time(); }; };
		end
		cache2:set(username, blocklist);
	end
	cache[username] = blocklist;
	return blocklist;
end

module:hook("iq-get/self/urn:xmpp:blocking:blocklist", function (event)
	local origin, stanza = event.origin, event.stanza;
	local username = origin.username;
	local reply = st.reply(stanza):tag("blocklist", { xmlns = "urn:xmpp:blocking" });
	local blocklist = cache[username] or get_blocklist(username);
	for jid in pairs(blocklist) do
		if jid then
			reply:tag("item", { jid = jid }):up();
		end
	end
	origin.interested_blocklist = true; -- Gets notified about changes
	origin.send(reply);
	return true;
end, -1);

-- Add or remove some jid(s) from the blocklist
-- We want this to be atomic and not do a partial update
local function edit_blocklist(event)
	local now = os.time();
	local origin, stanza = event.origin, event.stanza;
	local username = origin.username;
	local action = stanza.tags[1]; -- "block" or "unblock"
	local is_blocking = action.name == "block" and now or nil; -- nil if unblocking
	local new = {}; -- JIDs to block depending or unblock on action


	-- XEP-0191 sayeth:
	-- > When the user blocks communications with the contact, the user's
	-- > server MUST send unavailable presence information to the contact (but
	-- > only if the contact is allowed to receive presence notifications [...]
	-- So contacts we need to do that for are added to the set below.
	local send_unavailable = is_blocking and {};
	local send_available = not is_blocking and {};

	-- Because blocking someone currently also blocks the ability to reject
	-- subscription requests, we'll preemptively reject such
	local remove_pending = is_blocking and {};

	for item in action:childtags("item") do
		local jid = jid_prep(item.attr.jid);
		if not jid then
			origin.send(st_error_reply(stanza, "modify", "jid-malformed"));
			return true;
		end
		item.attr.jid = jid; -- echo back prepped
		new[jid] = true;
		if is_blocking then
			if is_contact_subscribed(username, module.host, jid) then
				send_unavailable[jid] = true;
			elseif is_contact_pending_in(username, module.host, jid) then
				remove_pending[jid] = true;
			end
		elseif is_contact_subscribed(username, module.host, jid) then
			send_available[jid] = true;
		end
	end

	if is_blocking and not next(new) then
		-- <block/> element does not contain at least one <item/> child element
		origin.send(st_error_reply(stanza, "modify", "bad-request"));
		return true;
	end

	local blocklist = cache[username] or get_blocklist(username);

	local new_blocklist = {
		-- We set the [false] key to something as a signal not to migrate privacy lists
		[false] = blocklist[false] or { created = now; };
	};
	if type(blocklist[false]) == "table" then
		new_blocklist[false].modified = now;
	end

	if is_blocking or next(new) then
		for jid, t in pairs(blocklist) do
			if jid then new_blocklist[jid] = t; end
		end
		for jid in pairs(new) do
			new_blocklist[jid] = is_blocking;
		end
		-- else empty the blocklist
	end

	local ok, err = set_blocklist(username, new_blocklist);
	if ok then
		origin.send(st.reply(stanza));
	else
		origin.send(st_error_reply(stanza, "wait", "internal-server-error", err));
		return true;
	end

	if is_blocking then
		for jid in pairs(send_unavailable) do
			-- Check that this JID isn't already blocked, i.e. this is not a change
			if not blocklist[jid] then
				for _, session in pairs(sessions[username].sessions) do
					if session.presence then
						module:send(st.presence({ type = "unavailable", to = jid, from = session.full_jid }));
					end
				end
			end
		end

		if next(remove_pending) then
			local roster = load_roster(username, module.host);
			for jid in pairs(remove_pending) do
				roster[false].pending[jid] = nil;
			end
			save_roster(username, module.host, roster);
			-- Not much we can do about save failing here
		end
	else
		local user_bare = username .. "@" .. module.host;
		for jid in pairs(send_available) do
			module:send(st.presence({ type = "probe", to = user_bare, from = jid }));
		end
	end

	local blocklist_push = st.iq({ type = "set", id = "blocklist-push" })
		:add_child(action); -- I am lazy

	for _, session in pairs(sessions[username].sessions) do
		if session.interested_blocklist then
			blocklist_push.attr.to = session.full_jid;
			session.send(blocklist_push);
		end
	end

	return true;
end

module:hook("iq-set/self/urn:xmpp:blocking:block", edit_blocklist, -1);
module:hook("iq-set/self/urn:xmpp:blocking:unblock", edit_blocklist, -1);

-- Cache invalidation, solved!
module:hook_global("user-deleted", function (event)
	if event.host == module.host then
		cache2:set(event.username, nil);
		cache[event.username] = nil;
	end
end);

-- Buggy clients
module:hook("iq-error/self/blocklist-push", function (event)
	local origin, stanza = event.origin, event.stanza;
	local _, condition, text = stanza:get_error();
	local log = (origin.log or module._log);
	log("warn", "Client returned an error in response to notification from mod_%s: %s%s%s",
		module.name, condition, text and ": " or "", text or "");
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
		origin.send(st_error_reply(stanza, "cancel", "service-unavailable"));
		return true;
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
	local stanza = event.stanza;
	local type = stanza.attr.type;
	if type == "chat" or not type or type == "normal" then
		if full_sessions[stanza.attr.to] then
			-- See #690
			return drop_stanza(event);
		end
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
		origin.send(st_error_reply(stanza, "cancel", "not-acceptable", "You have blocked this JID")
			:tag("blocked", { xmlns = "urn:xmpp:blocking:errors" }));
		return true;
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

module:hook("pre-presence/bare", bounce_outgoing, -1);
module:hook("pre-presence/host", bounce_outgoing, -1);
module:hook("pre-presence/full", bounce_outgoing, prio_out);

module:hook("pre-iq/bare", bounce_outgoing, prio_out);
module:hook("pre-iq/full", bounce_outgoing, prio_out);
module:hook("pre-iq/host", bounce_outgoing, prio_out);

