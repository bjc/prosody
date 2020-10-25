local t_unpack = table.unpack or unpack; -- luacheck: ignore 113
local time_now = os.time;

local jid_prep = require "util.jid".prep;
local set = require "util.set";
local st = require "util.stanza";
local it = require "util.iterators";
local uuid_generate = require "util.uuid".generate;
local dataform = require"util.dataforms".new;
local errors = require "util.error";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local _M = {};

local handlers = {};
_M.handlers = handlers;

local pubsub_errors = {
	["conflict"] = { "cancel", "conflict" };
	["invalid-jid"] = { "modify", "bad-request", nil, "invalid-jid" };
	["jid-required"] = { "modify", "bad-request", nil, "jid-required" };
	["nodeid-required"] = { "modify", "bad-request", nil, "nodeid-required" };
	["item-not-found"] = { "cancel", "item-not-found" };
	["not-subscribed"] = { "modify", "unexpected-request", nil, "not-subscribed" };
	["invalid-options"] = { "modify", "bad-request", nil, "invalid-options" };
	["forbidden"] = { "auth", "forbidden" };
	["not-allowed"] = { "cancel", "not-allowed" };
	["not-acceptable"] = { "modify", "not-acceptable" };
	["internal-server-error"] = { "wait", "internal-server-error" };
	["precondition-not-met"] = { "cancel", "conflict", nil, "precondition-not-met" };
	["invalid-item"] = { "modify", "bad-request", "invalid item" };
};
local function pubsub_error_reply(stanza, error)
	local e = pubsub_errors[error];
	if not e and errors.is_err(error) then
		e = { error.type, error.condition, error.text, error.pubsub_condition };
	end
	local reply = st.error_reply(stanza, t_unpack(e, 1, 3));
	if e[4] then
		reply:tag(e[4], { xmlns = xmlns_pubsub_errors }):up();
	end
	return reply;
end
_M.pubsub_error_reply = pubsub_error_reply;

local function dataform_error_message(err) -- ({ string : string }) -> string?
	local out = {};
	for field, errmsg in pairs(err) do
		table.insert(out, ("%s: %s"):format(field, errmsg))
	end
	return table.concat(out, "; ");
end

-- Note: If any config options are added that are of complex types,
-- (not simply strings/numbers) then the publish-options code will
-- need to be revisited
local node_config_form = dataform {
	{
		type = "hidden";
		var = "FORM_TYPE";
		value = "http://jabber.org/protocol/pubsub#node_config";
	};
	{
		type = "text-single";
		name = "title";
		var = "pubsub#title";
		label = "Title";
	};
	{
		type = "text-single";
		name = "description";
		var = "pubsub#description";
		label = "Description";
	};
	{
		type = "text-single";
		name = "payload_type";
		var = "pubsub#type";
		label = "The type of node data, usually specified by the namespace of the payload (if any)";
	};
	{
		type = "text-single";
		datatype = "xs:integer";
		name = "max_items";
		var = "pubsub#max_items";
		label = "Max # of items to persist";
	};
	{
		type = "boolean";
		name = "persist_items";
		var = "pubsub#persist_items";
		label = "Persist items to storage";
	};
	{
		type = "list-single";
		name = "access_model";
		var = "pubsub#access_model";
		label = "Specify the subscriber model";
		options = {
			"authorize",
			"open",
			"presence",
			"roster",
			"whitelist",
		};
	};
	{
		type = "list-single";
		name = "publish_model";
		var = "pubsub#publish_model";
		label = "Specify the publisher model";
		options = {
			"publishers";
			"subscribers";
			"open";
		};
	};
	{
		type = "boolean";
		value = true;
		label = "Whether to deliver event notifications";
		name = "notify_items";
		var = "pubsub#deliver_notifications";
	};
	{
		type = "boolean";
		value = true;
		label = "Whether to deliver payloads with event notifications";
		name = "include_payload";
		var = "pubsub#deliver_payloads";
	};
	{
		type = "list-single";
		name = "notification_type";
		var = "pubsub#notification_type";
		label = "Specify the delivery style for notifications";
		options = {
			{ label = "Messages of type normal", value = "normal" },
			{ label = "Messages of type headline", value = "headline", default = true },
		};
	};
	{
		type = "boolean";
		label = "Whether to notify subscribers when the node is deleted";
		name = "notify_delete";
		var = "pubsub#notify_delete";
		value = true;
	};
	{
		type = "boolean";
		label = "Whether to notify subscribers when items are removed from the node";
		name = "notify_retract";
		var = "pubsub#notify_retract";
		value = true;
	};
};

local subscribe_options_form = dataform {
	{
		type = "hidden";
		var = "FORM_TYPE";
		value = "http://jabber.org/protocol/pubsub#subscribe_options";
	};
	{
		type = "boolean";
		name = "pubsub#include_body";
		label = "Receive message body in addition to payload?";
	};
};

local node_metadata_form = dataform {
	{
		type = "hidden";
		var = "FORM_TYPE";
		value = "http://jabber.org/protocol/pubsub#meta-data";
	};
	{
		type = "text-single";
		name = "pubsub#title";
	};
	{
		type = "text-single";
		name = "pubsub#description";
	};
	{
		type = "text-single";
		name = "pubsub#type";
	};
	{
		type = "text-single";
		name = "pubsub#access_model";
	};
	{
		type = "text-single";
		name = "pubsub#publish_model";
	};
};

local service_method_feature_map = {
	add_subscription = { "subscribe", "subscription-options" };
	create = { "create-nodes", "instant-nodes", "item-ids", "create-and-configure" };
	delete = { "delete-nodes" };
	get_items = { "retrieve-items" };
	get_subscriptions = { "retrieve-subscriptions" };
	node_defaults = { "retrieve-default" };
	publish = { "publish", "multi-items", "publish-options" };
	purge = { "purge-nodes" };
	retract = { "delete-items", "retract-items" };
	set_node_config = { "config-node", "meta-data" };
	set_affiliation = { "modify-affiliations" };
};
local service_config_feature_map = {
	autocreate_on_publish = { "auto-create" };
};

function _M.get_feature_set(service)
	local supported_features = set.new();

	for method, features in pairs(service_method_feature_map) do
		if service[method] then
			for _, feature in ipairs(features) do
				if feature then
					supported_features:add(feature);
				end
			end
		end
	end

	for option, features in pairs(service_config_feature_map) do
		if service.config[option] then
			for _, feature in ipairs(features) do
				if feature then
					supported_features:add(feature);
				end
			end
		end
	end

	for affiliation in pairs(service.config.capabilities) do
		if affiliation ~= "none" and affiliation ~= "owner" then
			supported_features:add(affiliation.."-affiliation");
		end
	end

	if service.node_defaults.access_model then
		supported_features:add("access-"..service.node_defaults.access_model);
	end

	if rawget(service.config, "itemstore") and rawget(service.config, "nodestore") then
		supported_features:add("persistent-items");
	end

	return supported_features;
end

function _M.handle_disco_info_node(event, service)
	local stanza, reply, node = event.stanza, event.reply, event.node;
	local ok, ret = service:get_nodes(stanza.attr.from);
	local node_obj = ret[node];
	if not ok or not node_obj then
		return;
	end
	event.exists = true;
	reply:tag("identity", { category = "pubsub", type = "leaf" }):up();
	if node_obj.config then
		reply:add_child(node_metadata_form:form({
			["pubsub#title"] = node_obj.config.title;
			["pubsub#description"] = node_obj.config.description;
			["pubsub#type"] = node_obj.config.payload_type;
			["pubsub#access_model"] = node_obj.config.access_model;
			["pubsub#publish_model"] = node_obj.config.publish_model;
		}, "result"));
	end
end

function _M.handle_disco_items_node(event, service)
	local stanza, reply, node = event.stanza, event.reply, event.node;
	local ok, ret = service:get_items(node, stanza.attr.from);
	if not ok then
		return;
	end

	for _, id in ipairs(ret) do
		reply:tag("item", { jid = module.host, name = id }):up();
	end
	event.exists = true;
end

function _M.handle_pubsub_iq(event, service)
	local origin, stanza = event.origin, event.stanza;
	local pubsub_tag = stanza.tags[1];
	local action = pubsub_tag.tags[1];
	if not action then
		return origin.send(st.error_reply(stanza, "cancel", "bad-request"));
	end
	local prefix = "";
	if pubsub_tag.attr.xmlns == xmlns_pubsub_owner then
		prefix = "owner_";
	end
	local handler = handlers[prefix..stanza.attr.type.."_"..action.name];
	if handler then
		handler(origin, stanza, action, service);
		return true;
	end
end

function handlers.get_items(origin, stanza, items, service)
	local node = items.attr.node;

	local requested_items = {};
	for item in items:childtags("item") do
		table.insert(requested_items, item.attr.id);
	end
	if requested_items[1] == nil then
		requested_items = nil;
	end

	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local ok, results = service:get_items(node, stanza.attr.from, requested_items);
	if not ok then
		origin.send(pubsub_error_reply(stanza, results));
		return true;
	end

	local data = st.stanza("items", { node = node });
	for _, id in ipairs(results) do
		data:add_child(results[id]);
	end
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:add_child(data);
	origin.send(reply);
	return true;
end

function handlers.get_subscriptions(origin, stanza, subscriptions, service)
	local node = subscriptions.attr.node;
	local ok, ret = service:get_subscriptions(node, stanza.attr.from, stanza.attr.from);
	if not ok then
		origin.send(pubsub_error_reply(stanza, ret));
		return true;
	end
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:tag("subscriptions");
	for _, sub in ipairs(ret) do
		reply:tag("subscription", { node = sub.node, jid = sub.jid, subscription = 'subscribed' }):up();
	end
	origin.send(reply);
	return true;
end

function handlers.owner_get_subscriptions(origin, stanza, subscriptions, service)
	local node = subscriptions.attr.node;
	local ok, ret = service:get_subscriptions(node, stanza.attr.from);
	if not ok then
		origin.send(pubsub_error_reply(stanza, ret));
		return true;
	end
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("subscriptions");
	for _, sub in ipairs(ret) do
		reply:tag("subscription", { node = sub.node, jid = sub.jid, subscription = 'subscribed' }):up();
	end
	origin.send(reply);
	return true;
end

function handlers.owner_set_subscriptions(origin, stanza, subscriptions, service)
	local node = subscriptions.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	if not service:may(node, stanza.attr.from, "subscribe_other") then
		origin.send(pubsub_error_reply(stanza, "forbidden"));
		return true;
	end

	local node_obj = service.nodes[node];
	if not node_obj then
		origin.send(pubsub_error_reply(stanza, "item-not-found"));
		return true;
	end

	for subscription_tag in subscriptions:childtags("subscription") do
		if subscription_tag.attr.subscription == 'subscribed' then
			local ok, err = service:add_subscription(node, stanza.attr.from, subscription_tag.attr.jid);
			if not ok then
				origin.send(pubsub_error_reply(stanza, err));
				return true;
			end
		elseif subscription_tag.attr.subscription == 'none' then
			local ok, err = service:remove_subscription(node, stanza.attr.from, subscription_tag.attr.jid);
			if not ok then
				origin.send(pubsub_error_reply(stanza, err));
				return true;
			end
		end
	end

	local reply = st.reply(stanza);
	origin.send(reply);
	return true;
end

function handlers.set_create(origin, stanza, create, service)
	local node = create.attr.node;
	local ok, ret, reply;
	local config;
	local configure = stanza.tags[1]:get_child("configure");
	if configure then
		local config_form = configure:get_child("x", "jabber:x:data");
		if not config_form then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Missing dataform"));
			return true;
		end
		local form_data, err = node_config_form:data(config_form);
		if err then
			origin.send(st.error_reply(stanza, "modify", "bad-request", dataform_error_message(err)));
			return true;
		end
		config = form_data;
	end
	if node then
		ok, ret = service:create(node, stanza.attr.from, config);
		if ok then
			reply = st.reply(stanza);
		else
			reply = pubsub_error_reply(stanza, ret);
		end
	else
		repeat
			node = uuid_generate();
			ok, ret = service:create(node, stanza.attr.from, config);
		until ok or ret ~= "conflict";
		if ok then
			reply = st.reply(stanza)
				:tag("pubsub", { xmlns = xmlns_pubsub })
					:tag("create", { node = node });
		else
			reply = pubsub_error_reply(stanza, ret);
		end
	end
	origin.send(reply);
	return true;
end

function handlers.owner_set_delete(origin, stanza, delete, service)
	local node = delete.attr.node;

	local reply;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local ok, ret = service:delete(node, stanza.attr.from);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.set_subscribe(origin, stanza, subscribe, service)
	local node, jid = subscribe.attr.node, subscribe.attr.jid;
	jid = jid_prep(jid);
	if not (node and jid) then
		origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
		return true;
	end
	local options_tag, options = stanza.tags[1]:get_child("options"), nil;
	if options_tag then
		-- FIXME form parsing errors ignored here, why?
		local err
		options, err = subscribe_options_form:data(options_tag.tags[1]);
		if err then
			origin.send(st.error_reply(stanza, "modify", "bad-request", dataform_error_message(err)));
			return true
		end
	end
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

function handlers.set_unsubscribe(origin, stanza, unsubscribe, service)
	local node, jid = unsubscribe.attr.node, unsubscribe.attr.jid;
	jid = jid_prep(jid);
	if not (node and jid) then
		origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
		return true;
	end
	local ok, ret = service:remove_subscription(node, stanza.attr.from, jid);
	local reply;
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.get_options(origin, stanza, options, service)
	local node, jid = options.attr.node, options.attr.jid;
	jid = jid_prep(jid);
	if not (node and jid) then
		origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
		return true;
	end
	local ok, ret = service:get_subscription(node, stanza.attr.from, jid);
	if not ok then
		origin.send(pubsub_error_reply(stanza, "not-subscribed"));
		return true;
	end
	if ret == true then ret = {} end
	origin.send(st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:tag("options", { node = node, jid = jid })
				:add_child(subscribe_options_form:form(ret)));
	return true;
end

function handlers.set_options(origin, stanza, options, service)
	local node, jid = options.attr.node, options.attr.jid;
	jid = jid_prep(jid);
	if not (node and jid) then
		origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
		return true;
	end
	local ok, ret = service:get_subscription(node, stanza.attr.from, jid);
	if not ok then
		origin.send(pubsub_error_reply(stanza, ret));
		return true;
	elseif not ret then
		origin.send(pubsub_error_reply(stanza, "not-subscribed"));
		return true;
	end
	local old_subopts = ret;
	local new_subopts, err = subscribe_options_form:data(options.tags[1], old_subopts);
	if err then
		origin.send(st.error_reply(stanza, "modify", "bad-request", dataform_error_message(err)));
		return true;
	end
	local ok, err = service:add_subscription(node, stanza.attr.from, jid, new_subopts);
	if not ok then
		origin.send(pubsub_error_reply(stanza, err));
		return true;
	end
	origin.send(st.reply(stanza));
	return true;
end

function handlers.set_publish(origin, stanza, publish, service)
	local node = publish.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local required_config = nil;
	local publish_options = stanza.tags[1]:get_child("publish-options");
	if publish_options then
		-- Ensure that the node configuration matches the values in publish-options
		local publish_options_form = publish_options:get_child("x", "jabber:x:data");
		local err;
		required_config, err = node_config_form:data(publish_options_form);
		if err then
			origin.send(st.error_reply(stanza, "modify", "bad-request", dataform_error_message(err)));
			return true
		end
	end
	local item = publish:get_child("item");
	local id = (item and item.attr.id);
	if not id then
		id = uuid_generate();
		if item then
			item.attr.id = id;
		end
	end
	local ok, ret = service:publish(node, stanza.attr.from, id, item, required_config);
	local reply;
	if ok then
		if type(ok) == "string" then
			id = ok;
		end
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("publish", { node = node })
					:tag("item", { id = id });
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.set_retract(origin, stanza, retract, service)
	local node, notify = retract.attr.node, retract.attr.notify;
	notify = (notify == "1") or (notify == "true");
	local item = retract:get_child("item");
	local id = item and item.attr.id
	if not (node and id) then
		origin.send(pubsub_error_reply(stanza, node and "item-not-found" or "nodeid-required"));
		return true;
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
	origin.send(reply);
	return true;
end

function handlers.owner_set_purge(origin, stanza, purge, service)
	local node = purge.attr.node;
	local reply;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local ok, ret = service:purge(node, stanza.attr.from, true);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.owner_get_configure(origin, stanza, config, service)
	local node = config.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end

	local ok, node_config = service:get_node_config(node, stanza.attr.from);
	if not ok then
		origin.send(pubsub_error_reply(stanza, node_config));
		return true;
	end

	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("configure", { node = node })
				:add_child(node_config_form:form(node_config));
	origin.send(reply);
	return true;
end

function handlers.owner_set_configure(origin, stanza, config, service)
	local node = config.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	if not service:may(node, stanza.attr.from, "configure") then
		origin.send(pubsub_error_reply(stanza, "forbidden"));
		return true;
	end
	local config_form = config:get_child("x", "jabber:x:data");
	if not config_form then
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Missing dataform"));
		return true;
	end
	local ok, old_config = service:get_node_config(node, stanza.attr.from);
	if not ok then
		origin.send(pubsub_error_reply(stanza, old_config));
		return true;
	end
	local new_config, err = node_config_form:data(config_form, old_config);
	if err then
		origin.send(st.error_reply(stanza, "modify", "bad-request", dataform_error_message(err)));
		return true;
	end
	local ok, err = service:set_node_config(node, stanza.attr.from, new_config);
	if not ok then
		origin.send(pubsub_error_reply(stanza, err));
		return true;
	end
	origin.send(st.reply(stanza));
	return true;
end

function handlers.owner_get_default(origin, stanza, default, service) -- luacheck: ignore 212/default
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("default")
				:add_child(node_config_form:form(service.node_defaults));
	origin.send(reply);
	return true;
end

function handlers.owner_get_affiliations(origin, stanza, affiliations, service)
	local node = affiliations.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	if not service:may(node, stanza.attr.from, "set_affiliation") then
		origin.send(pubsub_error_reply(stanza, "forbidden"));
		return true;
	end

	local node_obj = service.nodes[node];
	if not node_obj then
		origin.send(pubsub_error_reply(stanza, "item-not-found"));
		return true;
	end

	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("affiliations", { node = node });

	for jid, affiliation in pairs(node_obj.affiliations) do
		reply:tag("affiliation", { jid = jid, affiliation = affiliation }):up();
	end

	origin.send(reply);
	return true;
end

function handlers.owner_set_affiliations(origin, stanza, affiliations, service)
	local node = affiliations.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	if not service:may(node, stanza.attr.from, "set_affiliation") then
		origin.send(pubsub_error_reply(stanza, "forbidden"));
		return true;
	end

	local node_obj = service.nodes[node];
	if not node_obj then
		origin.send(pubsub_error_reply(stanza, "item-not-found"));
		return true;
	end

	for affiliation_tag in affiliations:childtags("affiliation") do
		local jid = affiliation_tag.attr.jid;
		local affiliation = affiliation_tag.attr.affiliation;

		jid = jid_prep(jid);
		if affiliation == "none" then affiliation = nil; end

		local ok, err = service:set_affiliation(node, stanza.attr.from, jid, affiliation);
		if not ok then
			-- FIXME Incomplete error handling,
			-- see XEP 60 8.9.2.4 Multiple Simultaneous Modifications
			origin.send(pubsub_error_reply(stanza, err));
			return true;
		end
	end

	local reply = st.reply(stanza);
	origin.send(reply);
	return true;
end

local function create_encapsulating_item(id, payload)
	local item = st.stanza("item", { id = id, xmlns = xmlns_pubsub });
	item:add_child(payload);
	return item;
end

local function archive_itemstore(archive, config, user, node)
	module:log("debug", "Creation of itemstore for node %s with config %s", node, config);
	local get_set = {};
	local max_items = config["max_items"];
	function get_set:items() -- luacheck: ignore 212/self
		local data, err = archive:find(user, {
			limit = tonumber(max_items);
			reverse = true;
		});
		if not data then
			module:log("error", "Unable to get items: %s", err);
			return true;
		end
		module:log("debug", "Listed items %s", data);
		return it.reverse(function()
			-- luacheck: ignore 211/when
			local id, payload, when, publisher = data();
			if id == nil then
				return;
			end
			local item = create_encapsulating_item(id, payload, publisher);
			return id, item;
		end);
	end
	function get_set:get(key) -- luacheck: ignore 212/self
		local data, err = archive:find(user, {
			key = key;
			-- Get the last item with that key, if the archive doesn't deduplicate
			reverse = true,
			limit = 1;
		});
		if not data then
			module:log("error", "Unable to get item: %s", err);
			return nil, err;
		end
		local id, payload, when, publisher = data();
		module:log("debug", "Get item %s (published at %s by %s)", id, when, publisher);
		if id == nil then
			return nil;
		end
		return create_encapsulating_item(id, payload, publisher);
	end
	function get_set:set(key, value) -- luacheck: ignore 212/self
		local data, err;
		if value ~= nil then
			local publisher = value.attr.publisher;
			local payload = value.tags[1];
			data, err = archive:append(user, key, payload, time_now(), publisher);
		else
			data, err = archive:delete(user, { key = key; });
		end
		-- TODO archive support for maintaining maximum items
		archive:delete(user, {
			truncate = max_items;
		});
		if not data then
			module:log("error", "Unable to set item: %s", err);
			return nil, err;
		end
		return data;
	end
	function get_set:clear() -- luacheck: ignore 212/self
		return archive:delete(user);
	end
	function get_set:resize(size) -- luacheck: ignore 212/self
		max_items = size;
		return archive:delete(user, {
			truncate = size;
		});
	end
	function get_set:head()
		-- This should conveniently return the most recent item
		local item = self:get(nil);
		if item then
			return item.attr.id, item;
		end
	end
	return get_set;
end
_M.archive_itemstore = archive_itemstore;

return _M;
