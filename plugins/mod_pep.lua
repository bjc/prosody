
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local st = require "util.stanza";
local hosts = hosts;
local user_exists = require "core.usermanager".user_exists;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local pairs, ipairs = pairs, ipairs;
local next = next;
local load_roster = require "core.rostermanager".load_roster;

local data = {};
local recipients = {};

module:add_identity("pubsub", "pep");
module:add_feature("http://jabber.org/protocol/pubsub#publish");

local function publish(session, node, item)
	local disable = #item.tags ~= 1 or #item.tags[1].tags == 0;
	local stanza = st.message({from=session.full_jid, type='headline'})
		:tag('event', {xmlns='http://jabber.org/protocol/pubsub#event'})
			:tag('items', {node=node})
				:add_child(item)
			:up()
		:up();

	local bare = session.username..'@'..session.host;
	-- store for the future
	local user_data = data[bare];
	if disable then
		if user_data then user_data[node] = nil; end
		if not next(user_data) then data[bare] = nil; end
	else
		if not user_data then user_data = {}; data[bare] = user_data; end
		user_data[node] = stanza;
	end
	
	-- broadcast to resources
	stanza.attr.to = bare;
	core_route_stanza(session, stanza);

	-- broadcast to contacts
	for jid, item in pairs(session.roster) do
		if jid and jid ~= "pending" and (item.subscription == 'from' or item.subscription == 'both') then
			stanza.attr.to = jid;
			core_route_stanza(session, stanza);
		end
	end
end

module:hook("presence/bare", function(event)
	-- inbound presence to bare JID recieved
	local origin, stanza = event.origin, event.stanza;
	
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local bare = jid_bare(stanza.attr.from);
	local item = load_roster(jid_split(user))[bare];
	if not stanza.attr.to or (item and (item.subscription == 'from' or item.subscription == 'both')) then
		local t = stanza.attr.type;
		local recipient = stanza.attr.from;
		if t == "unavailable" or t == "error" then
			if recipients[user] then recipients[user][recipient] = nil; end
		elseif not t then
			recipients[user] = recipients[user] or {};
			if not recipients[user][recipient] then
				recipients[user][recipient] = true;
				for node, message in pairs(data[user] or {}) do
					message.attr.to = stanza.attr.from;
					origin.send(message);
				end
			end
		end
	end
end, 10);

module:add_iq_handler("c2s", "http://jabber.org/protocol/pubsub", function (session, stanza)
	if stanza.attr.type == 'set' and (not stanza.attr.to or jid_bare(stanza.attr.from) == stanza.attr.to) then
		local payload = stanza.tags[1];
		if payload.name == 'pubsub' then -- <pubsub xmlns='http://jabber.org/protocol/pubsub'>
			payload = payload.tags[1];
			if payload and payload.name == 'publish' and payload.attr.node then -- <publish node='http://jabber.org/protocol/tune'>
				local node = payload.attr.node;
				payload = payload.tags[1];
				if payload then -- <item>
					publish(session, node, payload);
					return true;
				end -- TODO else error
			end -- TODO else error
		end
	end
	session.send(st.error_reply(stanza, "cancel", "service-unavailable"));
end);

