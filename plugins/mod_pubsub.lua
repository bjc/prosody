local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local uuid_generate = require "util.uuid".generate;
local usermanager = require "core.usermanager";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local autocreate_on_publish = module:get_option_boolean("autocreate_on_publish", false);
local autocreate_on_subscribe = module:get_option_boolean("autocreate_on_subscribe", false);
local pubsub_disco_name = module:get_option("name");
if type(pubsub_disco_name) ~= "string" then pubsub_disco_name = "Prosody PubSub Service"; end

local service;

local handlers = {};

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
	if not action then
		return origin.send(st.error_reply(stanza, "cancel", "bad-request"));
	end
	local handler = handlers[stanza.attr.type.."_"..action.name];
	if handler then
		handler(origin, stanza, action);
		return true;
	end
end

local pubsub_errors = {
	["conflict"] = { "cancel", "conflict" };
	["invalid-jid"] = { "modify", "bad-request", nil, "invalid-jid" };
	["jid-required"] = { "modify", "bad-request", nil, "jid-required" };
	["nodeid-required"] = { "modify", "bad-request", nil, "nodeid-required" };
	["item-not-found"] = { "cancel", "item-not-found" };
	["not-subscribed"] = { "modify", "unexpected-request", nil, "not-subscribed" };
	["forbidden"] = { "cancel", "forbidden" };
};
function pubsub_error_reply(stanza, error)
	local e = pubsub_errors[error];
	local reply = st.error_reply(stanza, unpack(e, 1, 3));
	if e[4] then
		reply:tag(e[4], { xmlns = xmlns_pubsub_errors }):up();
	end
	return reply;
end

function handlers.get_items(origin, stanza, items)
	local node = items.attr.node;
	local item = items:get_child("item");
	local id = item and item.attr.id;
	
	if not node then
		return origin.send(pubsub_error_reply(stanza, "nodeid-required"));
	end
	local ok, results = service:get_items(node, stanza.attr.from, id);
	if not ok then
		return origin.send(pubsub_error_reply(stanza, results));
	end
	
	local data = st.stanza("items", { node = node });
	for _, entry in pairs(results) do
		data:add_child(entry);
	end
	local reply;
	if data then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:add_child(data);
	else
		reply = pubsub_error_reply(stanza, "item-not-found");
	end
	return origin.send(reply);
end

function handlers.get_subscriptions(origin, stanza, subscriptions)
	local node = subscriptions.attr.node;
	if not node then
		return origin.send(pubsub_error_reply(stanza, "nodeid-required"));
	end
	local ok, ret = service:get_subscriptions(node, stanza.attr.from, stanza.attr.from);
	if not ok then
		return origin.send(pubsub_error_reply(stanza, ret));
	end
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:tag("subscriptions");
	for _, sub in ipairs(ret) do
		reply:tag("subscription", { node = sub.node, jid = sub.jid, subscription = 'subscribed' }):up();
	end
	return origin.send(reply);
end

function handlers.set_create(origin, stanza, create)
	local node = create.attr.node;
	local ok, ret, reply;
	if node then
		ok, ret = service:create(node, stanza.attr.from);
		if ok then
			reply = st.reply(stanza);
		else
			reply = pubsub_error_reply(stanza, ret);
		end
	else
		repeat
			node = uuid_generate();
			ok, ret = service:create(node, stanza.attr.from);
		until ok or ret ~= "conflict";
		if ok then
			reply = st.reply(stanza)
				:tag("pubsub", { xmlns = xmlns_pubsub })
					:tag("create", { node = node });
		else
			reply = pubsub_error_reply(stanza, ret);
		end
	end
	return origin.send(reply);
end

function handlers.set_delete(origin, stanza, delete)
	local node = delete.attr.node;

	local reply, notifier;
	if not node then
		return origin.send(pubsub_error_reply(stanza, "nodeid-required"));
	end
	local ok, ret = service:delete(node, stanza.attr.from);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function handlers.set_subscribe(origin, stanza, subscribe)
	local node, jid = subscribe.attr.node, subscribe.attr.jid;
	if not (node and jid) then
		return origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
	end
	--[[
	local options_tag, options = stanza.tags[1]:get_child("options"), nil;
	if options_tag then
		options = options_form:data(options_tag.tags[1]);
	end
	--]]
	local options_tag, options; -- FIXME
	local ok, ret = service:add_subscription(node, stanza.attr.from, jid, options);
	local reply;
	if ok then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("subscription", {
					node = node,
					jid = jid,
					subscription = "subscribed"
				}):up();
		if options_tag then
			reply:add_child(options_tag);
		end
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
end

function handlers.set_unsubscribe(origin, stanza, unsubscribe)
	local node, jid = unsubscribe.attr.node, unsubscribe.attr.jid;
	if not (node and jid) then
		return origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
	end
	local ok, ret = service:remove_subscription(node, stanza.attr.from, jid);
	local reply;
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function handlers.set_publish(origin, stanza, publish)
	local node = publish.attr.node;
	if not node then
		return origin.send(pubsub_error_reply(stanza, "nodeid-required"));
	end
	local item = publish:get_child("item");
	local id = (item and item.attr.id);
	if not id then
		id = uuid_generate();
		if item then
			item.attr.id = id;
		end
	end
	local ok, ret = service:publish(node, stanza.attr.from, id, item);
	local reply;
	if ok then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("publish", { node = node })
					:tag("item", { id = id });
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function handlers.set_retract(origin, stanza, retract)
	local node, notify = retract.attr.node, retract.attr.notify;
	notify = (notify == "1") or (notify == "true");
	local item = retract:get_child("item");
	local id = item and item.attr.id
	if not (node and id) then
		return origin.send(pubsub_error_reply(stanza, node and "item-not-found" or "nodeid-required"));
	end
	local reply, notifier;
	if notify then
		notifier = st.stanza("retract", { id = id });
	end
	local ok, ret = service:retract(node, stanza.attr.from, id, notifier);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function handlers.set_purge(origin, stanza, purge)
	local node, notify = purge.attr.node, purge.attr.notify;
	notify = (notify == "1") or (notify == "true");
	local reply;
	if not node then
		return origin.send(pubsub_error_reply(stanza, "nodeid-required"));
	end
	local ok, ret = service:purge(node, stanza.attr.from, notify);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function simple_broadcast(kind, node, jids, item)
	if item then
		item = st.clone(item);
		item.attr.xmlns = nil; -- Clear the pubsub namespace
	end
	local message = st.message({ from = module.host, type = "headline" })
		:tag("event", { xmlns = xmlns_pubsub_event })
			:tag(kind, { node = node })
				:add_child(item);
	for jid in pairs(jids) do
		module:log("debug", "Sending notification to %s", jid);
		message.attr.to = jid;
		module:send(message);
	end
end

module:hook("iq/host/"..xmlns_pubsub..":pubsub", handle_pubsub_iq);
module:hook("iq/host/"..xmlns_pubsub_owner..":pubsub", handle_pubsub_iq);

local disco_info;

local feature_map = {
	create = { "create-nodes", "instant-nodes", "item-ids" };
	retract = { "delete-items", "retract-items" };
	purge = { "purge-nodes" };
	publish = { "publish", autocreate_on_publish and "auto-create" };
	delete = { "delete-nodes" };
	get_items = { "retrieve-items" };
	add_subscription = { "subscribe" };
	get_subscriptions = { "retrieve-subscriptions" };
};

local function add_disco_features_from_service(disco, service)
	for method, features in pairs(feature_map) do
		if service[method] then
			for _, feature in ipairs(features) do
				if feature then
					disco:tag("feature", { var = xmlns_pubsub.."#"..feature }):up();
				end
			end
		end
	end
	for affiliation in pairs(service.config.capabilities) do
		if affiliation ~= "none" and affiliation ~= "owner" then
			disco:tag("feature", { var = xmlns_pubsub.."#"..affiliation.."-affiliation" }):up();
		end
	end
end

local function build_disco_info(service)
	local disco_info = st.stanza("query", { xmlns = "http://jabber.org/protocol/disco#info" })
		:tag("identity", { category = "pubsub", type = "service", name = pubsub_disco_name }):up()
		:tag("feature", { var = "http://jabber.org/protocol/pubsub" }):up();
	add_disco_features_from_service(disco_info, service);
	return disco_info;
end

module:hook("iq-get/host/http://jabber.org/protocol/disco#info:query", function (event)
	local origin, stanza = event.origin, event.stanza;
	local node = stanza.tags[1].attr.node;
	if not node then
		return origin.send(st.reply(stanza):add_child(disco_info));
	else
		local ok, ret = service:get_nodes(stanza.attr.from);
		if ok and not ret[node] then
			ok, ret = false, "item-not-found";
		end
		if not ok then
			return origin.send(pubsub_error_reply(stanza, ret));
		end
		local reply = st.reply(stanza)
			:tag("query", { xmlns = "http://jabber.org/protocol/disco#info", node = node })
				:tag("identity", { category = "pubsub", type = "leaf" });
		return origin.send(reply);
	end
end);

local function handle_disco_items_on_node(event)
	local stanza, origin = event.stanza, event.origin;
	local query = stanza.tags[1];
	local node = query.attr.node;
	local ok, ret = service:get_items(node, stanza.attr.from);
	if not ok then
		return origin.send(pubsub_error_reply(stanza, ret));
	end
	
	local reply = st.reply(stanza)
		:tag("query", { xmlns = "http://jabber.org/protocol/disco#items", node = node });
	
	for id, item in pairs(ret) do
		reply:tag("item", { jid = module.host, name = id }):up();
	end
	
	return origin.send(reply);
end


module:hook("iq-get/host/http://jabber.org/protocol/disco#items:query", function (event)
	if event.stanza.tags[1].attr.node then
		return handle_disco_items_on_node(event);
	end
	local ok, ret = service:get_nodes(event.stanza.attr.from);
	if not ok then
		event.origin.send(pubsub_error_reply(event.stanza, ret));
	else
		local reply = st.reply(event.stanza)
			:tag("query", { xmlns = "http://jabber.org/protocol/disco#items" });
		for node, node_obj in pairs(ret) do
			reply:tag("item", { jid = module.host, node = node, name = node_obj.config.name }):up();
		end
		event.origin.send(reply);
	end
	return true;
end);

local admin_aff = module:get_option_string("default_admin_affiliation", "owner");
local function get_affiliation(jid)
	local bare_jid = jid_bare(jid);
	if bare_jid == module.host or usermanager.is_admin(bare_jid, module.host) then
		return admin_aff;
	end
end

function set_service(new_service)
	service = new_service;
	module.environment.service = service;
	disco_info = build_disco_info(service);
end

function module.save()
	return { service = service };
end

function module.restore(data)
	set_service(data.service);
end

set_service(pubsub.new({
	capabilities = {
		none = {
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
	
	autocreate_on_publish = autocreate_on_publish;
	autocreate_on_subscribe = autocreate_on_subscribe;
	
	broadcaster = simple_broadcast;
	get_affiliation = get_affiliation;
	
	normalize_jid = jid_bare;
}));
