-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local st = require "util.stanza";
local hosts = hosts;
local user_exists = require "core.usermanager".user_exists;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local pairs, ipairs = pairs, ipairs;
local next = next;
local type = type;
local sha1 = require "util.hashes".sha1;
local base64 = require "util.encodings".base64.encode;

local NULL = {};
local data = {};
local recipients = {};
local hash_map = {};

module.save = function()
	return { data = data, recipients = recipients, hash_map = hash_map };
end
module.restore = function(state)
	data = state.data or {};
	recipients = state.recipients or {};
	hash_map = state.hash_map or {};
end

module:add_identity("pubsub", "pep", "Prosody");
module:add_feature("http://jabber.org/protocol/pubsub#publish");

local function subscription_presence(user_bare, recipient)
	local recipient_bare = jid_bare(recipient);
	if (recipient_bare == user_bare) then return true end
	local username, host = jid_split(user_bare);
	return is_contact_subscribed(username, host, recipient_bare);
end

local function publish(session, node, id, item)
	item.attr.xmlns = nil;
	local disable = #item.tags ~= 1 or #item.tags[1] == 0;
	if #item.tags == 0 then item.name = "retract"; end
	local bare = session.username..'@'..session.host;
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
		user_data[node] = {id or "1", item};
	end

	-- broadcast
	for recipient, notify in pairs(recipients[bare] or NULL) do
		if notify[node] then
			stanza.attr.to = recipient;
			core_post_stanza(session, stanza);
		end
	end
end
local function publish_all(user, recipient, session)
	local d = data[user];
	local notify = recipients[user] and recipients[user][recipient];
	if d and notify then
		for node in pairs(notify) do
			if d[node] then
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
	-- inbound presence to bare JID recieved
	local origin, stanza = event.origin, event.stanza;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local t = stanza.attr.type;

	if not t then -- available presence
		if not stanza.attr.to or subscription_presence(user, stanza.attr.from) then
			local recipient = stanza.attr.from;
			local current = recipients[user] and recipients[user][recipient];
			local hash = get_caps_hash_from_presence(stanza, current);
			if current == hash then return; end
			if not hash then
				if recipients[user] then recipients[user][recipient] = nil; end
			else
				recipients[user] = recipients[user] or {};
				if hash_map[hash] then
					recipients[user][recipient] = hash_map[hash];
					publish_all(user, recipient, origin);
				else
					recipients[user][recipient] = hash;
					origin.send(
						st.stanza("iq", {from=stanza.attr.to, to=stanza.attr.from, id="disco", type="get"})
							:query("http://jabber.org/protocol/disco#info")
					);
				end
			end
		end
	elseif t == "unavailable" then
		if recipients[user] then recipients[user][stanza.attr.from] = nil; end
	end
end, 10);

module:hook("iq/bare/http://jabber.org/protocol/pubsub:pubsub", function(event)
	local session, stanza = event.origin, event.stanza;
	local payload = stanza.tags[1];

	if stanza.attr.type == 'set' and (not stanza.attr.to or jid_bare(stanza.attr.from) == stanza.attr.to) then
		payload = payload.tags[1];
		if payload and (payload.name == 'publish' or payload.name == 'retract') and payload.attr.node then -- <publish node='http://jabber.org/protocol/tune'>
			local node = payload.attr.node;
			payload = payload.tags[1];
			if payload and payload.name == "item" then -- <item>
				local id = payload.attr.id;
				session.send(st.reply(stanza));
				publish(session, node, id, st.clone(payload));
				return true;
			end
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
					local stanza = st.reply(stanza)
						:tag('pubsub', {xmlns='http://jabber.org/protocol/pubsub'})
							:tag('items', {node=node})
								:add_child(item)
							:up()
						:up();
					session.send(stanza);
					return true;
				else -- requested item doesn't exist
					local stanza = st.reply(stanza)
						:tag('pubsub', {xmlns='http://jabber.org/protocol/pubsub'})
							:tag('items', {node=node})
						:up();
					session.send(stanza);
					return true;
				end
			elseif node then -- node doesn't exist
				session.send(st.error_reply(stanza, 'cancel', 'item-not-found'));
				return true;
			else --invalid request
				session.send(st.error_reply(stanza, 'modify', 'bad-request'));
				return true;
			end
		else --no presence subscription
			session.send(st.error_reply(stanza, 'auth', 'not-authorized')
				:tag('presence-subscription-required', {xmlns='http://jabber.org/protocol/pubsub#errors'}));
			return true;
		end
	end
end);

local function calculate_hash(disco_info)
	local identities, features, extensions = {}, {}, {};
	for _, tag in pairs(disco_info) do
		if tag.name == "identity" then
			table.insert(identities, (tag.attr.category or "").."\0"..(tag.attr.type or "").."\0"..(tag.attr["xml:lang"] or "").."\0"..(tag.attr.name or ""));
		elseif tag.name == "feature" then
			table.insert(features, tag.attr.var or "");
		elseif tag.name == "x" and tag.attr.xmlns == "jabber:x:data" then
			local form = {};
			local FORM_TYPE;
			for _, field in pairs(tag.tags) do
				if field.name == "field" and field.attr.var then
					local values = {};
					for _, val in pairs(field.tags) do
						val = #val.tags == 0 and table.concat(val); -- FIXME use get_text?
						if val then table.insert(values, val); end
					end
					table.sort(values);
					if field.attr.var == "FORM_TYPE" then
						FORM_TYPE = values[1];
					elseif #values > 0 then
						table.insert(form, field.attr.var.."\0"..table.concat(values, "<"));
					else
						table.insert(form, field.attr.var);
					end
				end
			end
			table.sort(form);
			form = table.concat(form, "<");
			if FORM_TYPE then form = FORM_TYPE.."\0"..form; end
			table.insert(extensions, form);
		end
	end
	table.sort(identities);
	table.sort(features);
	table.sort(extensions);
	if #identities > 0 then identities = table.concat(identities, "<"):gsub("%z", "/").."<"; else identities = ""; end
	if #features > 0 then features = table.concat(features, "<").."<"; else features = ""; end
	if #extensions > 0 then extensions = table.concat(extensions, "<"):gsub("%z", "<").."<"; else extensions = ""; end
	local S = identities..features..extensions;
	local ver = base64(sha1(S));
	return ver, S;
end

module:hook("iq/bare/disco", function(event)
	local session, stanza = event.origin, event.stanza;
	if stanza.attr.type == "result" then
		local disco = stanza.tags[1];
		if disco and disco.name == "query" and disco.attr.xmlns == "http://jabber.org/protocol/disco#info" then
			-- Process disco response
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
			recipients[user][contact] = notify; -- set recipient's data to calculated data
			-- send messages to recipient
			publish_all(user, contact, session);
		end
	end
end);

module:hook("account-disco-info", function(event)
	local stanza = event.stanza;
	stanza:tag('identity', {category='pubsub', type='pep'}):up();
	stanza:tag('feature', {var='http://jabber.org/protocol/pubsub#publish'}):up();
end);

module:hook("account-disco-items", function(event)
	local stanza = event.stanza;
	local bare = stanza.attr.to;
	local user_data = data[bare];

	if user_data then
		for node, _ in pairs(user_data) do
			stanza:tag('item', {jid=bare, node=node}):up(); -- TODO we need to handle queries to these nodes
		end
	end
end);
