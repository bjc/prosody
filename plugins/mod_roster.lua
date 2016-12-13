-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "util.stanza"

local jid_split = require "util.jid".split;
local jid_prep = require "util.jid".prep;
local t_concat = table.concat;
local tonumber = tonumber;
local pairs, ipairs = pairs, ipairs;

local rm_load_roster = require "core.rostermanager".load_roster;
local rm_remove_from_roster = require "core.rostermanager".remove_from_roster;
local rm_add_to_roster = require "core.rostermanager".add_to_roster;
local rm_roster_push = require "core.rostermanager".roster_push;

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
						roster:tag("group"):text(group):up();
					end
					roster:up(); -- move out from item
				end
			end
			roster.tags[1].attr.ver = server_ver;
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
			local node, host, resource = jid_split(jid);
			if not resource and host then
				if jid ~= from_node.."@"..from_host then
					if item.attr.subscription == "remove" then
						local roster = session.roster;
						local r_item = roster[jid];
						if r_item then
							module:fire_event("roster-item-removed", {
								username = node, jid = jid, item = r_item, origin = session, roster = roster,
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
						for _, child in ipairs(item) do
							if child.name == "group" then
								local text = t_concat(child);
								if text and text ~= "" then
									r_item.groups[text] = true;
								end
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
	local bare = username .. "@" .. host;
	local roster = rm_load_roster(username, host);
	for jid, item in pairs(roster) do
		if jid then
			module:fire_event("roster-item-removed", {
				username = username, jid = jid, item = item, roster = roster, origin = origin,
			});
		else
			for jid in pairs(item.pending) do
				module:fire_event("roster-item-removed", {
					username = username, jid = jid, roster = roster, origin = origin,
				});
			end
		end
	end
end, 300);
