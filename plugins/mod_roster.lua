-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "prosody.util.stanza"

local jid_split = require "prosody.util.jid".split;
local jid_resource = require "prosody.util.jid".resource;
local jid_prep = require "prosody.util.jid".prep;
local tonumber = tonumber;
local pairs = pairs;

local rostermanager = require "prosody.core.rostermanager";
local rm_load_roster = rostermanager.load_roster;
local rm_remove_from_roster = rostermanager.remove_from_roster;
local rm_add_to_roster = rostermanager.add_to_roster;
local rm_roster_push = rostermanager.roster_push;

module:add_feature("jabber:iq:roster");

local rosterver_stream_feature = st.stanza("ver", {xmlns="urn:xmpp:features:rosterver"});
module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if origin.username then
		features:add_child(rosterver_stream_feature);
	end
end);

module:hook("iq/self/jabber:iq:roster:query", function(event)
	local session, stanza = event.origin, event.stanza;

	if stanza.attr.type == "get" then
		local roster = st.reply(stanza);

		local client_ver = tonumber(stanza.tags[1].attr.ver);
		local server_ver = tonumber(session.roster[false].version or 1);

		if not (client_ver and server_ver) or client_ver ~= server_ver then
			roster:query("jabber:iq:roster");
			-- Client does not support versioning, or has stale roster
			for jid, item in pairs(session.roster) do
				if jid then
					roster:tag("item", {
						jid = jid,
						subscription = item.subscription,
						ask = item.ask,
						name = item.name,
					});
					for group in pairs(item.groups) do
						roster:text_tag("group", group);
					end
					roster:up(); -- move out from item
				end
			end
			roster.tags[1].attr.ver = tostring(server_ver);
		end
		session.send(roster);
		session.interested = true; -- resource is interested in roster updates
	else -- stanza.attr.type == "set"
		local query = stanza.tags[1];
		if #query.tags == 1 and query.tags[1].name == "item"
				and query.tags[1].attr.xmlns == "jabber:iq:roster" and query.tags[1].attr.jid then
			local item = query.tags[1];
			local from_node, from_host = jid_split(stanza.attr.from);
			local jid = jid_prep(item.attr.jid);
			if jid and not jid_resource(jid) then
				if jid ~= from_node.."@"..from_host then
					if item.attr.subscription == "remove" then
						local roster = session.roster;
						local r_item = roster[jid];
						if r_item then
							module:fire_event("roster-item-removed", {
								username = from_node, jid = jid, item = r_item, origin = session, roster = roster,
							});
							local success, err_type, err_cond, err_msg = rm_remove_from_roster(session, jid);
							if success then
								session.send(st.reply(stanza));
								rm_roster_push(from_node, from_host, jid);
							else
								session.send(st.error_reply(stanza, err_type, err_cond, err_msg));
							end
						else
							session.send(st.error_reply(stanza, "modify", "item-not-found"));
						end
					else
						local r_item = {name = item.attr.name, groups = {}};
						if r_item.name == "" then r_item.name = nil; end
						if session.roster[jid] then
							r_item.subscription = session.roster[jid].subscription;
							r_item.ask = session.roster[jid].ask;
						else
							r_item.subscription = "none";
						end
						for group in item:childtags("group") do
							local text = group:get_text();
							if text then
								r_item.groups[text] = true;
							end
						end
						local success, err_type, err_cond, err_msg = rm_add_to_roster(session, jid, r_item);
						if success then
							-- Ok, send success
							session.send(st.reply(stanza));
							-- and push change to all resources
							rm_roster_push(from_node, from_host, jid);
						else
							-- Adding to roster failed
							session.send(st.error_reply(stanza, err_type, err_cond, err_msg));
						end
					end
				else
					-- Trying to add self to roster
					session.send(st.error_reply(stanza, "cancel", "not-allowed"));
				end
			else
				-- Invalid JID added to roster
				session.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME what's the correct error?
			end
		else
			-- Roster set didn't include a single item, or its name wasn't  'item'
			session.send(st.error_reply(stanza, "modify", "bad-request"));
		end
	end
	return true;
end);

module:hook_global("user-deleted", function(event)
	local username, host = event.username, event.host;
	local origin = event.origin or prosody.hosts[host];
	if host ~= module.host then return end
	local roster = rm_load_roster(username, host);
	for jid, item in pairs(roster) do
		if jid then
			module:fire_event("roster-item-removed", {
				username = username, jid = jid, item = item, roster = roster, origin = origin,
			});
		else
			for pending_jid in pairs(item.pending) do
				module:fire_event("roster-item-removed", {
					username = username, jid = pending_jid, roster = roster, origin = origin,
				});
			end
		end
	end
end, 300);

-- API/commands

-- Make a *one-way* subscription. User will see when contact is online,
-- contact will not see when user is online.
function subscribe(user_jid, contact_jid)
	local user_username, user_host = jid_split(user_jid);
	local contact_username, contact_host = jid_split(contact_jid);

	-- Update user's roster to say subscription request is pending. Bare hosts (e.g. components) don't have rosters.
	if user_username ~= nil then
		rostermanager.set_contact_pending_out(user_username, user_host, contact_jid);
	end

	if prosody.hosts[contact_host] then -- Sending to a local host?
		-- Update contact's roster to say subscription request is pending...
		rostermanager.set_contact_pending_in(contact_username, contact_host, user_jid);
		-- Update contact's roster to say subscription request approved...
		rostermanager.subscribed(contact_username, contact_host, user_jid);
		-- Update user's roster to say subscription request approved. Bare hosts (e.g. components) don't have rosters.
		if user_username ~= nil then
			rostermanager.process_inbound_subscription_approval(user_username, user_host, contact_jid);
		end
	else
		-- Send a subscription request
		local sub_request = st.presence({ from = user_jid, to = contact_jid, type = "subscribe" });
		module:send(sub_request);
	end

	return true;
end

-- Make a mutual subscription between jid1 and jid2. Each JID will see
-- when the other one is online.
function subscribe_both(jid1, jid2)
	local ok1, err1 = subscribe(jid1, jid2);
	local ok2, err2 = subscribe(jid2, jid1);
	return ok1 and ok2, err1 or err2;
end

-- Unsubscribes user from contact (not contact from user, if subscribed).
function unsubscribe(user_jid, contact_jid)
	local user_username, user_host = jid_split(user_jid);
	local contact_username, contact_host = jid_split(contact_jid);

	-- Update user's roster to say subscription is cancelled...
	rostermanager.unsubscribe(user_username, user_host, contact_jid);
	if prosody.hosts[contact_host] then -- Local host?
		-- Update contact's roster to say subscription is cancelled...
		rostermanager.unsubscribed(contact_username, contact_host, user_jid);
	end
	return true;
end

-- Cancel any subscription in either direction.
function unsubscribe_both(jid1, jid2)
	local ok1 = unsubscribe(jid1, jid2);
	local ok2 = unsubscribe(jid2, jid1);
	return ok1 and ok2;
end

module:add_item("shell-command", {
	section = "roster";
	section_desc = "View and manage user rosters (contact lists)";
	name = "show";
	desc = "Show a user's current roster";
	args = {
		{ name = "jid", type = "string" };
		{ name = "sub", type = "string" };
	};
	host_selector = "jid";
	handler = function(self, jid, sub) --luacheck: ignore 212/self
		local print = self.session.print;
		local it = require "prosody.util.iterators";

		local roster = assert(rm_load_roster(jid_split(jid)));

		local function sort_func(a, b)
			if type(a) == "string" and type(b) == "string" then
				return a < b;
			else
				return a == false;
			end
		end

		local count = 0;
		if sub == "pending" then
			local pending_subs = roster[false].pending or {};
			for pending_jid in it.sorted_pairs(pending_subs) do
				print(pending_jid);
			end
		else
			for contact, item in it.sorted_pairs(roster, sort_func) do
				if contact and (not sub or sub == item.subscription) then
					count = count + 1;
					print(contact, ("sub=%s\task=%s"):format(item.subscription or "none", item.ask or "none"));
				end
			end
		end

		return true, ("Showing %d entries"):format(count);
	end;
});

module:add_item("shell-command", {
	section = "roster";
	section_desc = "View and manage user rosters (contact lists)";
	name = "subscribe";
	desc = "Subscribe a user to another JID";
	args = {
		{ name = "jid", type = "string" };
		{ name = "contact", type = "string" };
	};
	host_selector = "jid";
	handler = function(self, jid, contact) --luacheck: ignore 212/self
		return subscribe(jid, contact);
	end;
});

module:add_item("shell-command", {
	section = "roster";
	section_desc = "View and manage user rosters (contact lists)";
	name = "subscribe_both";
	desc = "Subscribe a user and a contact JID to each other";
	args = {
		{ name = "jid", type = "string" };
		{ name = "contact", type = "string" };
	};
	host_selector = "jid";
	handler = function(self, jid, contact) --luacheck: ignore 212/self
		return subscribe_both(jid, contact);
	end;
});


module:add_item("shell-command", {
	section = "roster";
	section_desc = "View and manage user rosters (contact lists)";
	name = "unsubscribe";
	desc = "Unsubscribe a user from another JID";
	args = {
		{ name = "jid", type = "string" };
		{ name = "contact", type = "string" };
	};
	host_selector = "jid";
	handler = function(self, jid, contact) --luacheck: ignore 212/self
		return unsubscribe(jid, contact);
	end;
});

module:add_item("shell-command", {
	section = "roster";
	section_desc = "View and manage user rosters (contact lists)";
	name = "unsubscribe_both";
	desc = "Unubscribe a user and a contact JID from each other";
	args = {
		{ name = "jid", type = "string" };
		{ name = "contact", type = "string" };
	};
	host_selector = "jid";
	handler = function(self, jid, contact) --luacheck: ignore 212/self
		return unsubscribe_both(jid, contact);
	end;
});

