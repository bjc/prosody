local pubsub = require "util.pubsub";
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local set_new = require "util.set".new;
local st = require "util.stanza";
local calculate_hash = require "util.caps".calculate_hash;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local lib_pubsub = module:require "pubsub";
local handlers = lib_pubsub.handlers;
local pubsub_error_reply = lib_pubsub.pubsub_error_reply;

local empty_set = set_new();

local services = {};
local recipients = {};
local hash_map = {};

function module.save()
	return { services = services };
end

function module.restore(data)
	services = data.services;
end

local function subscription_presence(user_bare, recipient)
	local recipient_bare = jid_bare(recipient);
	if (recipient_bare == user_bare) then return true; end
	local username, host = jid_split(user_bare);
	return is_contact_subscribed(username, host, recipient_bare);
end

local function get_broadcaster(name)
	local function simple_broadcast(kind, node, jids, item)
		if item then
			item = st.clone(item);
			item.attr.xmlns = nil; -- Clear the pubsub namespace
		end
		local message = st.message({ from = name, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag(kind, { node = node })
					:add_child(item);
		for jid in pairs(jids) do
			module:log("debug", "Sending notification to %s from %s: %s", jid, name, tostring(item));
			message.attr.to = jid;
			module:send(message);
		end
	end
	return simple_broadcast;
end

function get_pep_service(name)
	local service = services[name];
	if service then
		return service;
	end
	service = pubsub.new({
		capabilities = {
			none = {
				create = false;
				publish = false;
				retract = false;
				get_nodes = false;

				subscribe = false;
				unsubscribe = false;
				get_subscription = false;
				get_subscriptions = false;
				get_items = false;

				subscribe_other = false;
				unsubscribe_other = false;
				get_subscription_other = false;
				get_subscriptions_other = false;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = false;
			};
			subscriber = {
				create = false;
				publish = false;
				retract = false;
				get_nodes = true;

				subscribe = true;
				unsubscribe = true;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;

				subscribe_other = false;
				unsubscribe_other = false;
				get_subscription_other = false;
				get_subscriptions_other = false;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = false;
			};
			publisher = {
				create = false;
				publish = true;
				retract = true;
				get_nodes = true;

				subscribe = true;
				unsubscribe = true;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;

				subscribe_other = false;
				unsubscribe_other = false;
				get_subscription_other = false;
				get_subscriptions_other = false;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = false;
			};
			owner = {
				create = true;
				publish = true;
				retract = true;
				delete = true;
				get_nodes = true;
				configure = true;

				subscribe = true;
				unsubscribe = true;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;


				subscribe_other = true;
				unsubscribe_other = true;
				get_subscription_other = true;
				get_subscriptions_other = true;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = true;
			};
		};

		node_defaults = {
			["pubsub#max_items"] = "1";
		};

		autocreate_on_publish = true;
		autocreate_on_subscribe = true;

		broadcaster = get_broadcaster(name);
		get_affiliation = function (jid)
			if jid_bare(jid) == name then
				return "owner";
			elseif subscription_presence(name, jid) then
				return "subscriber";
			end
		end;

		normalize_jid = jid_bare;
	});
	services[name] = service;
	module:add_item("pep-service", { service = service, jid = name });
	return service;
end

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
	if not action then
		return origin.send(st.error_reply(stanza, "cancel", "bad-request"));
	end
	local service_name = stanza.attr.to or origin.username.."@"..origin.host
	local service = get_pep_service(service_name);
	local handler = handlers[stanza.attr.type.."_"..action.name];
	if handler then
		handler(origin, stanza, action, service);
		return true;
	end
end

module:hook("iq/bare/"..xmlns_pubsub..":pubsub", handle_pubsub_iq);
module:hook("iq/bare/"..xmlns_pubsub_owner..":pubsub", handle_pubsub_iq);

module:add_identity("pubsub", "pep", module:get_option_string("name", "Prosody"));
module:add_feature("http://jabber.org/protocol/pubsub#publish");

local function get_caps_hash_from_presence(stanza, current)
	local t = stanza.attr.type;
	if not t then
		local child = stanza:get_child("c", "http://jabber.org/protocol/caps");
		if child then
			local attr = child.attr;
			if attr.hash then -- new caps
				if attr.hash == 'sha-1' and attr.node and attr.ver then
					return attr.ver, attr.node.."#"..attr.ver;
				end
			else -- legacy caps
				if attr.node and attr.ver then
					return attr.node.."#"..attr.ver.."#"..(attr.ext or ""), attr.node.."#"..attr.ver;
				end
			end
		end
		return; -- no or bad caps
	elseif t == "unavailable" or t == "error" then
		return;
	end
	return current; -- no caps, could mean caps optimization, so return current
end

local function resend_last_item(jid, node, service)
	local ok, items = service:get_items(node, jid);
	if not ok then return; end
	for i, id in ipairs(items) do
		service.config.broadcaster("items", node, { [jid] = true }, items[id]);
	end
end

local function update_subscriptions(recipient, service_name, nodes)
	local service = get_pep_service(service_name);
	nodes = nodes or empty_set;

	local service_recipients = recipients[service_name];
	if not service_recipients then
		service_recipients = {};
		recipients[service_name] = service_recipients;
	end

	local current = service_recipients[recipient];
	if not current or type(current) ~= "table" then
		current = empty_set;
	end

	if (current == empty_set or current:empty()) and (nodes == empty_set or nodes:empty()) then
		return;
	end

	for node in current - nodes do
		service:remove_subscription(node, recipient, recipient);
	end

	for node in nodes - current do
		service:add_subscription(node, recipient, recipient);
		resend_last_item(recipient, node, service);
	end

	if nodes == empty_set or nodes:empty() then
		nodes = nil;
	end

	service_recipients[recipient] = nodes;
end

module:hook("presence/bare", function(event)
	-- inbound presence to bare JID recieved
	local origin, stanza = event.origin, event.stanza;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local t = stanza.attr.type;
	local self = not stanza.attr.to;
	local service = get_pep_service(user);

	if not t then -- available presence
		if self or subscription_presence(user, stanza.attr.from) then
			local recipient = stanza.attr.from;
			local current = recipients[user] and recipients[user][recipient];
			local hash, query_node = get_caps_hash_from_presence(stanza, current);
			if current == hash or (current and current == hash_map[hash]) then return; end
			if not hash then
				update_subscriptions(recipient, user);
			else
				recipients[user] = recipients[user] or {};
				if hash_map[hash] then
					update_subscriptions(recipient, user, hash_map[hash]);
				else
					recipients[user][recipient] = hash;
					local from_bare = origin.type == "c2s" and origin.username.."@"..origin.host;
					if self or origin.type ~= "c2s" or (recipients[from_bare] and recipients[from_bare][origin.full_jid]) ~= hash then
						-- COMPAT from ~= stanza.attr.to because OneTeam can't deal with missing from attribute
						origin.send(
							st.stanza("iq", {from=user, to=stanza.attr.from, id="disco", type="get"})
								:tag("query", {xmlns = "http://jabber.org/protocol/disco#info", node = query_node})
						);
					end
				end
			end
		end
	elseif t == "unavailable" then
		update_subscriptions(stanza.attr.from, user);
	elseif not self and t == "unsubscribe" then
		local from = jid_bare(stanza.attr.from);
		local subscriptions = recipients[user];
		if subscriptions then
			for subscriber in pairs(subscriptions) do
				if jid_bare(subscriber) == from then
					update_subscriptions(subscriber, user);
				end
			end
		end
	end
end, 10);

module:hook("iq-result/bare/disco", function(event)
	local origin, stanza = event.origin, event.stanza;
	local disco = stanza:get_child("query", "http://jabber.org/protocol/disco#info");
	if not disco then
		return;
	end

	-- Process disco response
	local self = not stanza.attr.to;
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local contact = stanza.attr.from;
	local current = recipients[user] and recipients[user][contact];
	if type(current) ~= "string" then return; end -- check if waiting for recipient's response
	local ver = current;
	if not string.find(current, "#") then
		ver = calculate_hash(disco.tags); -- calculate hash
	end
	local notify = set_new();
	for _, feature in pairs(disco.tags) do
		if feature.name == "feature" and feature.attr.var then
			local nfeature = feature.attr.var:match("^(.*)%+notify$");
			if nfeature then notify:add(nfeature); end
		end
	end
	hash_map[ver] = notify; -- update hash map
	if self then
		for jid, item in pairs(origin.roster) do -- for all interested contacts
			if item.subscription == "both" or item.subscription == "from" then
				if not recipients[jid] then recipients[jid] = {}; end
				update_subscriptions(contact, jid, notify);
			end
		end
	end
	update_subscriptions(contact, user, notify);
end);

module:hook("account-disco-info-node", function(event)
	local reply, stanza, origin = event.reply, event.stanza, event.origin;
	local service_name = stanza.attr.to or origin.username.."@"..origin.host
	local service = get_pep_service(service_name);
	local node = event.node;
	local ok = service:get_items(node, jid_bare(stanza.attr.from) or true);
	if not ok then return; end
	event.exists = true;
	reply:tag('identity', {category='pubsub', type='leaf'}):up();
end);

module:hook("account-disco-info", function(event)
	local reply = event.reply;
	reply:tag('identity', {category='pubsub', type='pep'}):up();
	reply:tag('feature', {var='http://jabber.org/protocol/pubsub#publish'}):up();
end);

module:hook("account-disco-items-node", function(event)
	local reply, stanza, origin = event.reply, event.stanza, event.origin;
	local node = event.node;
	local service_name = stanza.attr.to or origin.username.."@"..origin.host
	local service = get_pep_service(service_name);
	local ok, ret = service:get_items(node, jid_bare(stanza.attr.from) or true);
	if not ok then return; end
	event.exists = true;
	for _, id in ipairs(ret) do
		reply:tag("item", { jid = service_name, name = id }):up();
	end
end);

module:hook("account-disco-items", function(event)
	local reply, stanza, origin = event.reply, event.stanza, event.origin;

	local service_name = reply.attr.from or origin.username.."@"..origin.host
	local service = get_pep_service(service_name);
	local ok, ret = service:get_nodes(jid_bare(stanza.attr.from));
	if not ok then return; end

	for node, node_obj in pairs(ret) do
		reply:tag("item", { jid = service_name, node = node, name = node_obj.config.name }):up();
	end
end);
