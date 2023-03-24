-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local jid_bare = require "prosody.util.jid".bare;
local jid_split = require "prosody.util.jid".split;
local st = require "prosody.util.stanza";
local is_contact_subscribed = require "prosody.core.rostermanager".is_contact_subscribed;
local pairs = pairs;
local next = next;
local type = type;
local unpack = table.unpack;
local calculate_hash = require "prosody.util.caps".calculate_hash;
local core_post_stanza = prosody.core_post_stanza;
local bare_sessions = prosody.bare_sessions;

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";

-- Used as canonical 'empty table'
local NULL = {};
-- data[user_bare_jid][node] = item_stanza
local data = {};
--- recipients[user_bare_jid][contact_full_jid][subscribed_node] = true
local recipients = {};
-- hash_map[hash][subscribed_nodes] = true
local hash_map = {};

module.save = function()
	return { data = data, recipients = recipients, hash_map = hash_map };
end
module.restore = function(state)
	data = state.data or {};
	recipients = state.recipients or {};
	hash_map = state.hash_map or {};
end

local function subscription_presence(user_bare, recipient)
	local recipient_bare = jid_bare(recipient);
	if (recipient_bare == user_bare) then return true end
	local username, host = jid_split(user_bare);
	return is_contact_subscribed(username, host, recipient_bare);
end

module:hook("pep-publish-item", function (event)
	local session, bare, node, id, item = event.session, event.user, event.node, event.id, event.item;
	item.attr.xmlns = nil;
	local disable = #item.tags ~= 1 or #item.tags[1] == 0;
	if #item.tags == 0 then item.name = "retract"; end
	local stanza = st.message({from=bare, type='headline'})
		:tag('event', {xmlns='http://jabber.org/protocol/pubsub#event'})
			:tag('items', {node=node})
				:add_child(item)
			:up()
		:up();

	-- store for the future
	local user_data = data[bare];
	if disable then
		if user_data then
			user_data[node] = nil;
			if not next(user_data) then data[bare] = nil; end
		end
	else
		if not user_data then user_data = {}; data[bare] = user_data; end
		user_data[node] = {id, item};
	end

	-- broadcast
	for recipient, notify in pairs(recipients[bare] or NULL) do
		if notify[node] then
			stanza.attr.to = recipient;
			core_post_stanza(session, stanza);
		end
	end
end);

local function publish_all(user, recipient, session)
	local d = data[user];
	local notify = recipients[user] and recipients[user][recipient];
	if d and notify then
		for node in pairs(notify) do
			if d[node] then
				-- luacheck: ignore id
				local id, item = unpack(d[node]);
				session.send(st.message({from=user, to=recipient, type='headline'})
					:tag('event', {xmlns='http://jabber.org/protocol/pubsub#event'})
						:tag('items', {node=node})
							:add_child(item)
						:up()
					:up());
			end
		end
	end
end

local function get_caps_hash_from_presence(stanza, current)
	local t = stanza.attr.type;
	if not t then
		for _, child in pairs(stanza.tags) do
			if child.name == "c" and child.attr.xmlns == "http://jabber.org/protocol/caps" then
				local attr = child.attr;
				if attr.hash then -- new caps
					if attr.hash == 'sha-1' and attr.node and attr.ver then return attr.ver, attr.node.."#"..attr.ver; end
				else -- legacy caps
					if attr.node and attr.ver then return attr.node.."#"..attr.ver.."#"..(attr.ext or ""), attr.node.."#"..attr.ver; end
				end
				return; -- bad caps format
			end
		end
	elseif t == "unavailable" or t == "error" then
		return;
	end
	return current; -- no caps, could mean caps optimization, so return current
end

module:hook("presence/bare", function(event)
	-- inbound presence to bare JID received
	local origin, stanza = event.origin, event.stanza;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local t = stanza.attr.type;
	local self = not stanza.attr.to;

	-- Only cache subscriptions if user is online
	if not bare_sessions[user] then return; end

	if not t then -- available presence
		if self or subscription_presence(user, stanza.attr.from) then
			local recipient = stanza.attr.from;
			local current = recipients[user] and recipients[user][recipient];
			local hash = get_caps_hash_from_presence(stanza, current);
			if current == hash or (current and current == hash_map[hash]) then return; end
			if not hash then
				if recipients[user] then recipients[user][recipient] = nil; end
			else
				recipients[user] = recipients[user] or {};
				if hash_map[hash] then
					recipients[user][recipient] = hash_map[hash];
					publish_all(user, recipient, origin);
				else
					recipients[user][recipient] = hash;
					local from_bare = origin.type == "c2s" and origin.username.."@"..origin.host;
					if self or origin.type ~= "c2s" or (recipients[from_bare] and recipients[from_bare][origin.full_jid]) ~= hash then
						-- COMPAT from ~= stanza.attr.to because OneTeam and Asterisk 1.8 can't deal with missing from attribute
						origin.send(
							st.stanza("iq", {from=user, to=stanza.attr.from, id="disco", type="get"})
								:query("http://jabber.org/protocol/disco#info")
						);
					end
				end
			end
		end
	elseif t == "unavailable" then
		if recipients[user] then recipients[user][stanza.attr.from] = nil; end
	elseif not self and t == "unsubscribe" then
		local from = jid_bare(stanza.attr.from);
		local subscriptions = recipients[user];
		if subscriptions then
			for subscriber in pairs(subscriptions) do
				if jid_bare(subscriber) == from then
					recipients[user][subscriber] = nil;
				end
			end
		end
	end
end, 10);

module:hook("iq/bare/http://jabber.org/protocol/pubsub:pubsub", function(event)
	local session, stanza = event.origin, event.stanza;
	local payload = stanza.tags[1];

	if stanza.attr.type == 'set' and (not stanza.attr.to or jid_bare(stanza.attr.from) == stanza.attr.to) then
		payload = payload.tags[1]; -- <publish node='http://jabber.org/protocol/tune'>
		if payload and (payload.name == 'publish' or payload.name == 'retract') and payload.attr.node then
			local node = payload.attr.node;
			payload = payload.tags[1];
			if payload and payload.name == "item" then -- <item>
				local id = payload.attr.id or "1";
				payload.attr.id = id;
				session.send(st.reply(stanza));
				module:fire_event("pep-publish-item", {
					node = node, user = jid_bare(session.full_jid), actor = session.jid,
					id = id, session = session, item = st.clone(payload);
				});
				return true;
			else
				module:log("debug", "Payload is missing the <item>", node);
			end
		else
			module:log("debug", "Unhandled payload: %s", payload and payload:top_tag() or "(no payload)");
		end
	elseif stanza.attr.type == 'get' then
		local user = stanza.attr.to and jid_bare(stanza.attr.to) or session.username..'@'..session.host;
		if subscription_presence(user, stanza.attr.from) then
			local user_data = data[user];
			local node, requested_id;
			payload = payload.tags[1];
			if payload and payload.name == 'items' then
				node = payload.attr.node;
				local item = payload.tags[1];
				if item and item.name == "item" then
					requested_id = item.attr.id;
				end
			end
			if node and user_data and user_data[node] then -- Send the last item
				local id, item = unpack(user_data[node]);
				if not requested_id or id == requested_id then
					local reply_stanza = st.reply(stanza)
						:tag('pubsub', {xmlns='http://jabber.org/protocol/pubsub'})
							:tag('items', {node=node})
								:add_child(item)
							:up()
						:up();
					session.send(reply_stanza);
					return true;
				else -- requested item doesn't exist
					local reply_stanza = st.reply(stanza)
						:tag('pubsub', {xmlns='http://jabber.org/protocol/pubsub'})
							:tag('items', {node=node})
						:up();
					session.send(reply_stanza);
					return true;
				end
			elseif node then -- node doesn't exist
				session.send(st.error_reply(stanza, 'cancel', 'item-not-found'));
				module:log("debug", "Item '%s' not found", node)
				return true;
			else --invalid request
				session.send(st.error_reply(stanza, 'modify', 'bad-request'));
				module:log("debug", "Invalid request: %s", payload);
				return true;
			end
		else --no presence subscription
			session.send(st.error_reply(stanza, 'auth', 'not-authorized')
				:tag('presence-subscription-required', {xmlns='http://jabber.org/protocol/pubsub#errors'}));
			module:log("debug", "Unauthorized request: %s", payload);
			return true;
		end
	end
end);

module:hook("iq-result/bare/disco", function(event)
	local session, stanza = event.origin, event.stanza;
	if stanza.attr.type == "result" then
		local disco = stanza.tags[1];
		if disco and disco.name == "query" and disco.attr.xmlns == "http://jabber.org/protocol/disco#info" then
			-- Process disco response
			local self = not stanza.attr.to;
			local user = stanza.attr.to or (session.username..'@'..session.host);
			local contact = stanza.attr.from;
			local current = recipients[user] and recipients[user][contact];
			if type(current) ~= "string" then return; end -- check if waiting for recipient's response
			local ver = current;
			if not string.find(current, "#") then
				ver = calculate_hash(disco.tags); -- calculate hash
			end
			local notify = {};
			for _, feature in pairs(disco.tags) do
				if feature.name == "feature" and feature.attr.var then
					local nfeature = feature.attr.var:match("^(.*)%+notify$");
					if nfeature then notify[nfeature] = true; end
				end
			end
			hash_map[ver] = notify; -- update hash map
			if self then
				for jid, item in pairs(session.roster) do -- for all interested contacts
					if item.subscription == "both" or item.subscription == "from" then
						if not recipients[jid] then recipients[jid] = {}; end
						recipients[jid][contact] = notify;
						publish_all(jid, contact, session);
					end
				end
			end
			recipients[user][contact] = notify; -- set recipient's data to calculated data
			-- send messages to recipient
			publish_all(user, contact, session);
		end
	end
end);

module:hook("account-disco-info", function(event)
	local reply = event.reply;
	reply:tag('identity', {category='pubsub', type='pep'}):up();
	reply:tag('feature', {var=xmlns_pubsub}):up();
	local features = {
		"access-presence",
		"auto-create",
		"auto-subscribe",
		"filtered-notifications",
		"item-ids",
		"last-published",
		"presence-notifications",
		"presence-subscribe",
		"publish",
		"retract-items",
		"retrieve-items",
	};
	for _, feature in ipairs(features) do
		reply:tag('feature', {var=xmlns_pubsub.."#"..feature}):up();
	end
end);

module:hook("account-disco-items", function(event)
	local reply = event.reply;
	local bare = reply.attr.to;
	local user_data = data[bare];

	if user_data then
		for node, _ in pairs(user_data) do
			reply:tag('item', {jid=bare, node=node}):up();
		end
	end
end);

module:hook("account-disco-info-node", function (event)
	local stanza, node = event.stanza, event.node;
	local user = stanza.attr.to;
	local user_data = data[user];
	if user_data and user_data[node] then
		event.exists = true;
		event.reply:tag('identity', {category='pubsub', type='leaf'}):up();
	end
end);

module:hook("resource-unbind", function (event)
	local user_bare_jid = event.session.username.."@"..event.session.host;
	if not bare_sessions[user_bare_jid] then -- User went offline
		-- We don't need this info cached anymore, clear it.
		recipients[user_bare_jid] = nil;
	end
end);
