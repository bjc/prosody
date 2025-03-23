-- Prosody IM
-- Copyright (C) 2008-2017 Matthew Wild
-- Copyright (C) 2008-2017 Waqas Hussain
-- Copyright (C) 2011-2021 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- XEP-0313: Message Archive Management for Prosody
--

local xmlns_mam     = "urn:xmpp:mam:2";
local xmlns_mam_ext = "urn:xmpp:mam:2#extended";
local xmlns_delay   = "urn:xmpp:delay";
local xmlns_forward = "urn:xmpp:forward:0";
local xmlns_st_id   = "urn:xmpp:sid:0";

local um = require "prosody.core.usermanager";
local st = require "prosody.util.stanza";
local rsm = require "prosody.util.rsm";
local get_prefs = module:require"mamprefs".get;
local set_prefs = module:require"mamprefs".set;
local prefs_to_stanza = module:require"mamprefsxml".tostanza;
local prefs_from_stanza = module:require"mamprefsxml".fromstanza;
local jid_bare = require "prosody.util.jid".bare;
local jid_split = require "prosody.util.jid".split;
local jid_resource = require "prosody.util.jid".resource;
local jid_prepped_split = require "prosody.util.jid".prepped_split;
local dataform = require "prosody.util.dataforms".new;
local get_form_type = require "prosody.util.dataforms".get_type;
local host = module.host;

local rm_load_roster = require "prosody.core.rostermanager".load_roster;

local is_stanza = st.is_stanza;
local tostring = tostring;
local time_now = require "prosody.util.time".now;
local m_min = math.min;
local timestamp, datestamp = import( "util.datetime", "datetime", "date");
local default_max_items, max_max_items = 20, module:get_option_integer("max_archive_query_results", 50, 0);
local strip_tags = module:get_option_set("dont_archive_namespaces", { "http://jabber.org/protocol/chatstates" });

local archive_store = module:get_option_string("archive_store", "archive");
local archive = module:open_store(archive_store, "archive");

local cleanup_after = module:get_option_period("archive_expires_after", "1w");
local archive_item_limit = module:get_option_integer("storage_archive_item_limit", archive.caps and archive.caps.quota or 1000, 0);
local archive_truncate = math.floor(archive_item_limit * 0.99);

if not archive.find then
	error("mod_"..(archive._provided_by or archive.name and "storage_"..archive.name).." does not support archiving\n"
		.."See https://prosody.im/doc/storage and https://prosody.im/doc/archiving for more information");
end
local use_total = module:get_option_boolean("mam_include_total", true);

function schedule_cleanup(_username, _date) -- luacheck: ignore 212
	-- Called to make a note of which users have messages on which days, which in
	-- turn is used to optimize the message expiry routine.
	--
	-- This noop is conditionally replaced later depending on retention settings
	-- and storage backend capabilities.
end

-- Handle prefs.
module:hook("iq/self/"..xmlns_mam..":prefs", function(event)
	local origin, stanza = event.origin, event.stanza;
	local user = origin.username;
	if stanza.attr.type == "set" then
		local new_prefs = stanza:get_child("prefs", xmlns_mam);
		local prefs = prefs_from_stanza(new_prefs);
		local ok, err = set_prefs(user, prefs);
		if not ok then
			origin.send(st.error_reply(stanza, "cancel", "internal-server-error", "Error storing preferences: "..tostring(err)));
			return true;
		end
	end
	local prefs = prefs_to_stanza(get_prefs(user, true));
	local reply = st.reply(stanza):add_child(prefs);
	origin.send(reply);
	return true;
end);

local query_form = dataform {
	{ name = "FORM_TYPE"; type = "hidden"; value = xmlns_mam };
	{ name = "with"; type = "jid-single" };
	{ name = "start"; type = "text-single"; datatype = "xs:dateTime" };
	{ name = "end"; type = "text-single"; datatype = "xs:dateTime" };
};

if archive.caps and archive.caps.full_id_range then
	table.insert(query_form, { name = "before-id"; type = "text-single"; });
	table.insert(query_form, { name = "after-id"; type = "text-single"; });
end

if archive.caps and archive.caps.ids then
	table.insert(query_form, { name = "ids"; type = "list-multi"; });
end


-- Serve form
module:hook("iq-get/self/"..xmlns_mam..":query", function(event)
	local origin, stanza = event.origin, event.stanza;
	get_prefs(origin.username, true);
	origin.send(st.reply(stanza):query(xmlns_mam):add_child(query_form:form()));
	return true;
end);

-- Handle archive queries
module:hook("iq-set/self/"..xmlns_mam..":query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local query = stanza.tags[1];
	local qid = query.attr.queryid;

	origin.mam_requested = true;

	get_prefs(origin.username, true);

	-- Search query parameters
	local qwith, qstart, qend, qbefore, qafter, qids;
	local form = query:get_child("x", "jabber:x:data");
	if form then
		local form_type, err = get_form_type(form);
		if not form_type then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid dataform: "..err));
			return true;
		elseif form_type ~= xmlns_mam then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Unexpected FORM_TYPE, expected '"..xmlns_mam.."'"));
			return true;
		end
		form, err = query_form:data(form);
		if err then
			origin.send(st.error_reply(stanza, "modify", "bad-request", select(2, next(err))));
			return true;
		end
		qwith, qstart, qend = form["with"], form["start"], form["end"];
		qbefore, qafter = form["before-id"], form["after-id"];
		qids = form["ids"];
		qwith = qwith and jid_bare(qwith); -- dataforms does jidprep
	end

	-- RSM stuff
	local qset = rsm.get(query);
	local qmax = m_min(qset and qset.max or default_max_items, max_max_items);
	local reverse = qset and qset.before or false;

	local before, after = qset and qset.before or qbefore, qset and qset.after or qafter;
	if type(before) ~= "string" then before = nil; end

	-- A reverse query needs to be flipped
	local flip = reverse;
	-- A flip-page query needs to be the opposite of that.
	if query:get_child("flip-page") then flip = not flip end

	module:log("debug", "Archive query by %s id=%s with=%s when=%s...%s rsm=%q",
		origin.username,
		qid or stanza.attr.id,
		qwith or "*",
		qstart and timestamp(qstart) or "",
		qend and timestamp(qend) or "",
		qset);

	-- Load all the data!
	local data, err = archive:find(origin.username, {
		start = qstart; ["end"] = qend; -- Time range
		with = qwith;
		limit = qmax == 0 and 0 or qmax + 1;
		before = before; after = after;
		ids = qids;
		reverse = reverse;
		total = use_total or qmax == 0;
	});

	if not data then
		module:log("debug", "Archive query id=%s failed: %s", qid or stanza.attr.id, err);
		if err == "item-not-found" then
			origin.send(st.error_reply(stanza, "modify", "item-not-found"));
		else
			origin.send(st.error_reply(stanza, "cancel", "internal-server-error"));
		end
		return true;
	end
	local total = tonumber(err);

	local msg_reply_attr = { to = stanza.attr.from, from = stanza.attr.to };

	local results = {};

	-- Wrap it in stuff and deliver
	local first, last;
	local count = 0;
	local complete = "true";
	for id, item, when in data do
		count = count + 1;
		if count > qmax then
			-- We requested qmax+1 items. If that many items are retrieved then
			-- there are more results to page through, so:
			complete = nil;
			break;
		end
		local fwd_st = st.message(msg_reply_attr)
			:tag("result", { xmlns = xmlns_mam, queryid = qid, id = id })
				:tag("forwarded", { xmlns = xmlns_forward })
					:tag("delay", { xmlns = xmlns_delay, stamp = timestamp(when) }):up();

		if not is_stanza(item) then
			item = st.deserialize(item);
		end
		item.attr.xmlns = "jabber:client";
		fwd_st:add_child(item);

		if not first then first = id; end
		last = id;

		if flip then
			results[count] = fwd_st;
		else
			origin.send(fwd_st);
		end
	end

	if flip then
		for i = #results, 1, -1 do
			origin.send(results[i]);
		end
	end
	if reverse then
		first, last = last, first;
	end

	origin.send(st.reply(stanza)
		:tag("fin", { xmlns = xmlns_mam, complete = complete })
			:add_child(rsm.generate {
				first = first, last = last, count = total }));

	-- That's all folks!
	module:log("debug", "Archive query id=%s completed, %d items returned", qid or stanza.attr.id, complete and count or count - 1);
	return true;
end);

module:hook("iq-get/self/"..xmlns_mam..":metadata", function (event)
	local origin, stanza = event.origin, event.stanza;

	local reply = st.reply(stanza):tag("metadata", { xmlns = xmlns_mam });

	do
		local first = archive:find(origin.username, { limit = 1 });
		if not first then
			origin.send(st.error_reply(stanza, "cancel", "internal-server-error"));
			return true;
		end

		for id, _, when in first do
			reply:tag("start", { id = id, timestamp = timestamp(when) }):up();
		end
	end

	do
		local last = archive:find(origin.username, { limit = 1, reverse = true });
		if not last then
			origin.send(st.error_reply(stanza, "cancel", "internal-server-error"));
			return true;
		end

		for id, _, when in last do
			reply:tag("end", { id = id, timestamp = timestamp(when) }):up();
		end
	end

	origin.send(reply);
	return true;
end);

local function has_in_roster(user, who)
	local roster = rm_load_roster(user, host);
	module:log("debug", "%s has %s in roster? %s", user, who, roster[who] and "yes" or "no");
	return roster[who];
end

local function shall_store(user, who)
	-- TODO Cache this?
	if not um.user_exists(user, host) then
		module:log("debug", "%s@%s does not exist", user, host)
		return false;
	end
	local prefs = get_prefs(user);
	local rule = prefs[who];
	module:log("debug", "%s's rule for %s is %s", user, who, rule);
	if rule ~= nil then
		return rule;
	end
	-- Below could be done by a metatable
	local default = prefs[false];
	module:log("debug", "%s's default rule is %s", user, default);
	if default == "roster" then
		return has_in_roster(user, who);
	end
	return default;
end

local function strip_stanza_id(stanza, user)
	if stanza:get_child("stanza-id", xmlns_st_id) then
		stanza = st.clone(stanza);
		stanza:maptags(function (tag)
			if tag.name == "stanza-id" and tag.attr.xmlns == xmlns_st_id then
				local by_user, by_host, res = jid_prepped_split(tag.attr.by);
				if not res and by_host == host and by_user == user then
					return nil;
				end
			end
			return tag;
		end);
	end
	return stanza;
end

local function should_store(stanza) --> boolean, reason: string
	local st_type = stanza.attr.type or "normal";
	-- FIXME pass direction of stanza and use that along with bare/full JID addressing
	-- for more accurate MUC / type=groupchat check

	if st_type == "headline" then
		-- Headline messages are ephemeral by definition
		return false, "headline";
	end
	if st_type == "error" then
		-- Errors not sent sent from a local client
		-- Why would a client send an error anyway?
		if jid_resource(stanza.attr.to) then
			-- Store delivery failure notifications so you know if your own messages
			-- were not delivered.
			return true, "bounce";
		else
			-- Skip errors for messages that come from your account, such as PEP
			-- notifications.
			return false, "bounce";
		end
	end
	if st_type == "groupchat" then
		-- MUC messages always go to the full JID, usually archived by the MUC
		return false, "groupchat";
	end
	if stanza:get_child("no-store", "urn:xmpp:hints")
	or stanza:get_child("no-permanent-store", "urn:xmpp:hints") then
		return false, "hint";
	end
	if stanza:get_child("store", "urn:xmpp:hints") then
		return true, "hint";
	end
	if stanza:get_child("body") then
		return true, "body";
	end
	if stanza:get_child("subject") then
		-- XXX Who would send a message with a subject but without a body?
		return true, "subject";
	end
	if stanza:get_child("encryption", "urn:xmpp:eme:0") then
		-- Since we can't know what an encrypted message contains, we assume it's important
		-- XXX Experimental XEP
		return true, "encrypted";
	end
	if stanza:get_child(nil, "urn:xmpp:receipts") then
		-- If it's important enough to ask for a receipt then it's important enough to archive
		-- and the same applies to the receipt
		return true, "receipt";
	end
	if stanza:get_child(nil, "urn:xmpp:chat-markers:0") then
		return true, "marker";
	end
	if stanza:get_child("x", "jabber:x:conference")
	or stanza:find("{http://jabber.org/protocol/muc#user}x/invite") then
		return true, "invite";
	end
	if stanza:get_child(nil, "urn:xmpp:jingle-message:0") or stanza:get_child(nil, "urn:xmpp:jingle-message:1") then
		-- XXX Experimental XEP
		return true, "jingle call";
	end

	 -- The IM-NG thing to do here would be to return `not st_to_full`
	 -- One day ...
	return false, "default";
end

module:hook("archive-should-store", function (event)
	local should, why = should_store(event.stanza);
	event.reason = why;
	return should;
end, -1)

-- Handle messages
local function message_handler(event, c2s)
	local origin, stanza = event.origin, event.stanza;
	local log = c2s and origin.log or module._log;
	local orig_from = stanza.attr.from;
	local orig_to = stanza.attr.to or orig_from;
	-- Stanza without 'to' are treated as if it was to their own bare jid

	-- Whose storage do we put it in?
	local store_user = c2s and origin.username or jid_split(orig_to);
	-- And who are they chatting with?
	local with = jid_bare(c2s and orig_to or orig_from);

	-- Filter out <stanza-id> that claim to be from us
	event.stanza = strip_stanza_id(stanza, store_user);

	local event_payload = { stanza = stanza; session = origin };
	local should = module:fire_event("archive-should-store", event_payload);
	local why = event_payload.reason;

	if not should then
		log("debug", "Not archiving stanza: %s (%s)", stanza:top_tag(), event_payload.reason);
		return;
	end

	local clone_for_storage;
	if not strip_tags:empty() then
		clone_for_storage = st.clone(stanza);
		clone_for_storage:maptags(function (tag)
			if strip_tags:contains(tag.attr.xmlns) then
				return nil;
			else
				return tag;
			end
		end);
		if #clone_for_storage.tags == 0 then
			log("debug", "Not archiving stanza: %s (empty when stripped)", stanza:top_tag());
			return;
		end
	else
		clone_for_storage = stanza;
	end

	-- Check with the users preferences
	if shall_store(store_user, with) then
		log("debug", "Archiving stanza: %s (%s)", stanza:top_tag(), why);

		-- And stash it
		local time = time_now();
		local ok, err = archive:append(store_user, nil, clone_for_storage, time, with);
		if not ok and err == "quota-limit" then
			if cleanup_after ~= math.huge then
				module:log("debug", "User '%s' over quota, cleaning archive", store_user);
				local cleaned = archive:delete(store_user, {
					["end"] = (os.time() - cleanup_after);
				});
				if cleaned then
					ok, err = archive:append(store_user, nil, clone_for_storage, time, with);
				end
			end
			if not ok and (archive.caps and archive.caps.truncate) then
				module:log("debug", "User '%s' over quota, truncating archive", store_user);
				local truncated = archive:delete(store_user, {
					truncate = archive_truncate;
				});
				if truncated then
					ok, err = archive:append(store_user, nil, clone_for_storage, time, with);
				end
			end
		end
		if ok then
			local clone_for_other_handlers = st.clone(stanza);
			local id = ok;
			clone_for_other_handlers:tag("stanza-id", { xmlns = xmlns_st_id, by = store_user.."@"..host, id = id }):up();
			event.stanza = clone_for_other_handlers;
			schedule_cleanup(store_user);
			module:fire_event("archive-message-added", { origin = origin, stanza = clone_for_storage, for_user = store_user, id = id });
		else
			log("error", "Could not archive stanza: %s", err);
		end
	else
		log("debug", "Not archiving stanza: %s (prefs)", stanza:top_tag());
	end
end

local function c2s_message_handler(event)
	return message_handler(event, true);
end

-- Filter out <stanza-id> before the message leaves the server to prevent privacy leak.
local function strip_stanza_id_after_other_events(event)
	event.stanza = strip_stanza_id(event.stanza, event.origin.username);
end

module:hook("pre-message/bare", strip_stanza_id_after_other_events, -1);
module:hook("pre-message/full", strip_stanza_id_after_other_events, -1);

-- Catch messages not stored by mod_offline and mark them as stored if they
-- have been archived. This would generally only happen if mod_offline is
-- disabled.  Otherwise the message would generate a delivery failure report,
-- which would not be accurate because it has been archived.
module:hook("message/offline/handle", function(event)
	local stanza = event.stanza;
	local user = event.username .. "@" .. host;
	if stanza:get_child_with_attr("stanza-id", xmlns_st_id, "by", user) then
		return true;
	end
end, -2);

-- Don't broadcast offline messages to clients that have queried the archive.
module:hook("message/offline/broadcast", function (event)
	if event.origin.mam_requested then
		return true;
	end
end);

if cleanup_after ~= math.huge then
	local cleanup_storage = module:open_store("archive_cleanup");
	local cleanup_map = module:open_store("archive_cleanup", "map");

	module:log("debug", "archive_expires_after = %d -- in seconds", cleanup_after);

	if not archive.delete then
		module:log("error", "archive_expires_after set but mod_%s does not support deleting", archive._provided_by);
		return false;
	end

	-- For each day, store a set of users that have new messages. To expire
	-- messages, we collect the union of sets of users from dates that fall
	-- outside the cleanup range.

	if not (archive.caps and archive.caps.wildcard_delete) then
		local last_date = require "prosody.util.cache".new(module:get_option_integer("archive_cleanup_date_cache_size", 1000, 1));
		function schedule_cleanup(username, date)
			date = date or datestamp();
			if last_date:get(username) == date then return end
			local ok = cleanup_map:set(date, username, true);
			if ok then
				last_date:set(username, date);
			end
		end
	end

	local cleanup_time = module:measure("cleanup", "times");

	local async = require "prosody.util.async";
	module:daily("Remove expired messages", function ()
		local cleanup_done = cleanup_time();

		if archive.caps and archive.caps.wildcard_delete then
			local ok, err = archive:delete(true, { ["end"] = os.time() - cleanup_after })
			if ok then
				local sum = tonumber(ok);
				if sum then
					module:log("info", "Deleted %d expired messages", sum);
				else
					-- driver did not tell
					module:log("info", "Deleted all expired messages");
				end
			else
				module:log("error", "Could not delete messages: %s", err);
			end
			cleanup_done();
			return;
		end

		local users = {};
		local cut_off = datestamp(os.time() - cleanup_after);
		for date in cleanup_storage:users() do
			if date <= cut_off then
				module:log("debug", "Messages from %q should be expired", date);
				local messages_this_day = cleanup_storage:get(date);
				if messages_this_day then
					for user in pairs(messages_this_day) do
						users[user] = true;
					end
					if date < cut_off then
						-- Messages from the same day as the cut-off might not have expired yet,
						-- but all earlier will have, so clear storage for those days.
						cleanup_storage:set(date, nil);
					end
				end
			end
		end
		local sum, num_users = 0, 0;
		for user in pairs(users) do
			local ok, err = archive:delete(user, { ["end"] = os.time() - cleanup_after; })
			if ok then
				num_users = num_users + 1;
				sum = sum + (tonumber(ok) or 0);
			else
				cleanup_map:set(cut_off, user, true);
				module:log("error", "Could not delete messages for user '%s': %s", user, err);
			end
			local wait, done = async.waiter();
			module:add_timer(0.01, done);
			wait();
		end
		module:log("info", "Deleted %d expired messages for %d users", sum, num_users);
		cleanup_done();
	end);

else
	module:log("debug", "Archive expiry disabled");
	-- Don't ask the backend to count the potentially unbounded number of items,
	-- it'll get slow.
	use_total = module:get_option_boolean("mam_include_total", false);
end

-- Stanzas sent by local clients
module:hook("pre-message/bare", c2s_message_handler, 0);
module:hook("pre-message/full", c2s_message_handler, 0);
-- Stanzas to local clients
module:hook("message/bare", message_handler, 0);
module:hook("message/full", message_handler, 0);

local advertise_extended = archive.caps and archive.caps.full_id_range and archive.caps.ids;

module:hook("account-disco-info", function(event)
	(event.reply or event.stanza):tag("feature", {var=xmlns_mam}):up();
	if advertise_extended then
		(event.reply or event.stanza):tag("feature", {var=xmlns_mam_ext}):up();
	end
	(event.reply or event.stanza):tag("feature", {var=xmlns_st_id}):up();
end);

