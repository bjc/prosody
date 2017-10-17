local pubsub = require "util.pubsub";
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local jid_join = require "util.jid".join;
local set_new = require "util.set".new;
local st = require "util.stanza";
local calculate_hash = require "util.caps".calculate_hash;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local cache = require "util.cache";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local lib_pubsub = module:require "pubsub";
local handlers = lib_pubsub.handlers;

local empty_set = set_new();

local services = {};
local recipients = {};
local hash_map = {};

local host = module.host;

local known_nodes_map = module:open_store("pep", "map");
local known_nodes = module:open_store("pep");

function module.save()
	return { services = services };
end

function module.restore(data)
	services = data.services;
end

local function subscription_presence(username, recipient)
	local user_bare = jid_join(username, host);
	local recipient_bare = jid_bare(recipient);
	if (recipient_bare == user_bare) then return true; end
	return is_contact_subscribed(username, host, recipient_bare);
end

local function simple_itemstore(username)
	return function (config, node)
		if config["pubsub#persist_items"] then
			module:log("debug", "Creating new persistent item store for user %s, node %q", username, node);
			known_nodes_map:set(username, node, true);
			local archive = module:open_store("pep_"..node, "archive");
			return lib_pubsub.archive_itemstore(archive, config, username, node, false);
		else
			module:log("debug", "Creating new ephemeral item store for user %s, node %q", username, node);
			known_nodes_map:set(username, node, nil);
			return cache.new(tonumber(config["pubsub#max_items"]));
		end
	end
end

local function get_broadcaster(username)
	local user_bare = jid_join(username, host);
	local function simple_broadcast(kind, node, jids, item)
		if item then
			item = st.clone(item);
			item.attr.xmlns = nil; -- Clear the pubsub namespace
		end
		local message = st.message({ from = user_bare, type = "headline" })
			:tag("event", { xmlns = xmlns_pubsub_event })
				:tag(kind, { node = node })
					:add_child(item);
		for jid in pairs(jids) do
			module:log("debug", "Sending notification to %s from %s: %s", jid, user_bare, tostring(item));
			message.attr.to = jid;
			module:send(message);
		end
	end
	return simple_broadcast;
end

function get_pep_service(username)
	module:log("debug", "get_pep_service(%q)", username);
	local user_bare = jid_join(username, host);
	local service = services[username];
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
			["pubsub#persist_items"] = true;
		};

		autocreate_on_publish = true;
		autocreate_on_subscribe = true;

		itemstore = simple_itemstore(username);
		broadcaster = get_broadcaster(username);
		get_affiliation = function (jid)
			if jid_bare(jid) == user_bare then
				return "owner";
			elseif subscription_presence(username, jid) then
				return "subscriber";
			end
		end;

		normalize_jid = jid_bare;
	});
	local nodes, err = known_nodes:get(username);
	if nodes then
		module:log("debug", "Restoring nodes for user %s", username);
		for node in pairs(nodes) do
			module:log("debug", "Restoring node %q", node);
			service:create(node, true);
		end
	elseif err then
		module:log("error", "Could not restore nodes for %s: %s", username, err);
	else
		module:log("debug", "No known nodes");
	end
	services[username] = service;
	module:add_item("pep-service", { service = service, jid = user_bare });
	return service;
end

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local pubsub_tag = stanza.tags[1];
	local action = pubsub_tag.tags[1];
	if not action then
		return origin.send(st.error_reply(stanza, "cancel", "bad-request"));
	end
	local service_name = origin.username;
	if stanza.attr.to ~= nil then
		service_name = jid_split(stanza.attr.to);
	end
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
	for _, id in ipairs(items) do
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
	local t = stanza.attr.type;
	local is_self = not stanza.attr.to;
	local username = jid_split(stanza.attr.to);
	local user_bare = jid_bare(stanza.attr.to);
	if is_self then
		username = origin.username;
		user_bare = jid_join(username, host);
	end

	if not t then -- available presence
		if is_self or subscription_presence(username, stanza.attr.from) then
			local recipient = stanza.attr.from;
			local current = recipients[username] and recipients[username][recipient];
			local hash, query_node = get_caps_hash_from_presence(stanza, current);
			if current == hash or (current and current == hash_map[hash]) then return; end
			if not hash then
				update_subscriptions(recipient, username);
			else
				recipients[username] = recipients[username] or {};
				if hash_map[hash] then
					update_subscriptions(recipient, username, hash_map[hash]);
				else
					recipients[username][recipient] = hash;
					local from_bare = origin.type == "c2s" and origin.username.."@"..origin.host;
					if is_self or origin.type ~= "c2s" or (recipients[from_bare] and recipients[from_bare][origin.full_jid]) ~= hash then
						-- COMPAT from ~= stanza.attr.to because OneTeam can't deal with missing from attribute
						origin.send(
							st.stanza("iq", {from=user_bare, to=stanza.attr.from, id="disco", type="get"})
								:tag("query", {xmlns = "http://jabber.org/protocol/disco#info", node = query_node})
						);
					end
				end
			end
		end
	elseif t == "unavailable" then
		update_subscriptions(stanza.attr.from, username);
	elseif not is_self and t == "unsubscribe" then
		local from = jid_bare(stanza.attr.from);
		local subscriptions = recipients[username];
		if subscriptions then
			for subscriber in pairs(subscriptions) do
				if jid_bare(subscriber) == from then
					update_subscriptions(subscriber, username);
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
	local is_self = stanza.attr.to == nil;
	local user_bare = jid_bare(stanza.attr.to);
	local username = jid_split(stanza.attr.to);
	if is_self then
		username = origin.username;
		user_bare = jid_join(username, host);
	end
	local contact = stanza.attr.from;
	local current = recipients[username] and recipients[username][contact];
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
	if is_self then
		-- Optimization: Fiddle with other local users
		for jid, item in pairs(origin.roster) do -- for all interested contacts
			if jid then
				local contact_node, contact_host = jid_split(jid);
				if contact_host == host and item.subscription == "both" or item.subscription == "from" then
					update_subscriptions(user_bare, contact_node, notify);
				end
			end
		end
	end
	update_subscriptions(contact, username, notify);
end);

module:hook("account-disco-info-node", function(event)
	local reply, stanza, origin = event.reply, event.stanza, event.origin;
	local service_name = origin.username;
	if stanza.attr.to ~= nil then
		service_name = jid_split(stanza.attr.to);
	end
	local service = get_pep_service(service_name);
	local node = event.node;
	local ok = service:get_items(node, jid_bare(stanza.attr.from) or true);
	if not ok then return; end
	event.exists = true;
	reply:tag('identity', {category='pubsub', type='leaf'}):up();
end);

module:hook("account-disco-info", function(event)
	local origin, reply = event.origin, event.reply;

	reply:tag('identity', {category='pubsub', type='pep'}):up();
	reply:tag('feature', {var=xmlns_pubsub}):up();

	local username = jid_split(reply.attr.from) or origin.username;
	local service = get_pep_service(username);

	local feature_map = {
		create = { "create-nodes", "instant-nodes", "item-ids" };
		retract = { "delete-items", "retract-items" };
		purge = { "purge-nodes" };
		publish = { "publish", service.config.autocreate_on_publish and "auto-create" };
		delete = { "delete-nodes" };
		get_items = { "retrieve-items" };
		add_subscription = { "subscribe" };
		get_subscriptions = { "retrieve-subscriptions" };
		set_node_config = { "config-node" };
		node_defaults = { "retrieve-default" };
	};

	for method, features in pairs(feature_map) do
		if service[method] then
			for _, feature in ipairs(features) do
				if feature then
					reply:tag('feature', {var=xmlns_pubsub.."#"..feature}):up();
				end
			end
		end
	end
	for affiliation in pairs(service.config.capabilities) do
		if affiliation ~= "none" and affiliation ~= "owner" then
			reply:tag('feature', {var=xmlns_pubsub.."#"..affiliation.."-affiliation"}):up();
		end
	end

	-- Features not covered by the above
	local more_features = {
		"access-presence",
		"auto-subscribe",
		"filtered-notifications",
		"last-published",
		"persistent-items",
		"presence-notifications",
		"presence-subscribe",
	};
	for _, feature in ipairs(more_features) do
		reply:tag('feature', {var=xmlns_pubsub.."#"..feature}):up();
	end
end);

module:hook("account-disco-items-node", function(event)
	local reply, stanza, origin = event.reply, event.stanza, event.origin;
	local node = event.node;
	local is_self = stanza.attr.to == nil;
	local user_bare = jid_bare(stanza.attr.to);
	local username = jid_split(stanza.attr.to);
	if is_self then
		username = origin.username;
		user_bare = jid_join(username, host);
	end
	local service = get_pep_service(username);
	local ok, ret = service:get_items(node, jid_bare(stanza.attr.from) or true);
	if not ok then return; end
	event.exists = true;
	for _, id in ipairs(ret) do
		reply:tag("item", { jid = user_bare, name = id }):up();
	end
end);

module:hook("account-disco-items", function(event)
	local reply, stanza, origin = event.reply, event.stanza, event.origin;

	local is_self = stanza.attr.to == nil;
	local user_bare = jid_bare(stanza.attr.to);
	local username = jid_split(stanza.attr.to);
	if is_self then
		username = origin.username;
		user_bare = jid_join(username, host);
	end
	local service = get_pep_service(username);

	local ok, ret = service:get_nodes(jid_bare(stanza.attr.from));
	if not ok then return; end

	for node, node_obj in pairs(ret) do
		reply:tag("item", { jid = user_bare, node = node, name = node_obj.config.name }):up();
	end
end);
