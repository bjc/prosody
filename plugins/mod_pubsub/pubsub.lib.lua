local t_unpack = table.unpack or unpack; -- luacheck: ignore 113
local time_now = os.time;

local st = require "util.stanza";
local uuid_generate = require "util.uuid".generate;
local dataform = require"util.dataforms".new;

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
	["forbidden"] = { "auth", "forbidden" };
	["not-allowed"] = { "cancel", "not-allowed" };
};
local function pubsub_error_reply(stanza, error)
	local e = pubsub_errors[error];
	local reply = st.error_reply(stanza, t_unpack(e, 1, 3));
	if e[4] then
		reply:tag(e[4], { xmlns = xmlns_pubsub_errors }):up();
	end
	return reply;
end
_M.pubsub_error_reply = pubsub_error_reply;

local node_config_form = dataform {
	{
		type = "hidden";
		name = "FORM_TYPE";
		value = "http://jabber.org/protocol/pubsub#node_config";
	};
	{
		type = "text-single";
		name = "pubsub#max_items";
		label = "Max # of items to persist";
	};
};

function handlers.get_items(origin, stanza, items, service)
	local node = items.attr.node;
	local item = items:get_child("item");
	local item_id = item and item.attr.id;

	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local ok, results = service:get_items(node, stanza.attr.from, item_id);
	if not ok then
		origin.send(pubsub_error_reply(stanza, results));
		return true;
	end

	local data = st.stanza("items", { node = node });
	for _, id in ipairs(results) do
		data:add_child(results[id]);
	end
	local reply;
	if data then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:add_child(data);
	else
		reply = pubsub_error_reply(stanza, "item-not-found");
	end
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

function handlers.set_create(origin, stanza, create, service)
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
	origin.send(reply);
	return true;
end

function handlers.set_delete(origin, stanza, delete, service)
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
	if not (node and jid) then
		origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
		return true;
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

function handlers.set_unsubscribe(origin, stanza, unsubscribe, service)
	local node, jid = unsubscribe.attr.node, unsubscribe.attr.jid;
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

function handlers.set_publish(origin, stanza, publish, service)
	local node = publish.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
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

function handlers.set_purge(origin, stanza, purge, service)
	local node, notify = purge.attr.node, purge.attr.notify;
	notify = (notify == "1") or (notify == "true");
	local reply;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local ok, ret = service:purge(node, stanza.attr.from, notify);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.get_configure(origin, stanza, config, service)
	local node = config.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end

	if not service:may(node, stanza.attr.from, "configure") then
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
			:tag("configure", { node = node })
				:add_child(node_config_form:form(node_obj.config));
	origin.send(reply);
	return true;
end

function handlers.set_configure(origin, stanza, config, service)
	local node = config.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	if not service:may(node, stanza.attr.from, "configure") then
		origin.send(pubsub_error_reply(stanza, "forbidden"));
		return true;
	end
	local new_config, err = node_config_form:data(config.tags[1]);
	if not new_config then
		origin.send(st.error_reply(stanza, "modify", "bad-request", err));
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

function handlers.get_default(origin, stanza, default, service)
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("default")
				:add_child(node_config_form:form(service.node_defaults));
	origin.send(reply);
	return true;
end

local function create_encapsulating_item(id, payload, publisher, expose_publisher)
	local item = st.stanza("item", { id = id, xmlns = xmlns_pubsub });
	item:add_child(payload);
	if expose_publisher then
		item.attr.publisher = publisher;
	end
	return item;
end

local function simple_itemstore(archive, config, node, expose_publisher)
	module:log("debug", "Creation of itemstore for node %s with config %s", node, config);
	local get_set = {};
	function get_set:items()
		local store = self.store;
		local data, err = archive:find(node);
		if not data then
			module:log("error", "Unable to get items: %s", err);
			return true;
		end
		module:log("debug", "Listed items %s from store %s", data, store);
		return function()
			local id, payload, when, publisher = data();
			if id == nil then
				return;
			end
			local item = create_encapsulating_item(id, payload, publisher, expose_publisher);
			return id, item;
		end;
	end
	function get_set:get(key)
		local store = self.store;
		local data, err = archive:find(node, {
			key = key;
		});
		if not data then
			module:log("error", "Unable to get item: %s", err);
			return nil, err;
		end
		-- Workaround for buggy SQL drivers which require iterating until we get a nil.
		local id, payload, when, publisher;
		for a, b, c, d in data() do
			id, payload, when, publisher = a, b, c, d;
		end
		module:log("debug", "Get item %s (published at %s by %s) from store %s", id, when, publisher, store);
		if id == nil then
			return nil;
		end
		return create_encapsulating_item(id, payload, publisher, expose_publisher);
	end
	function get_set:set(key, value)
		local store = self.store;
		module:log("debug", "Set item %s to %s for %s in store %s", key, value, node, store);
		local data, err;
		if value ~= nil then
			local publisher = value.attr.publisher;
			local payload = value.tags[1];
			data, err = archive:append(node, key, payload, time_now(), publisher);
		else
			data, err = archive:delete(node, {
				key = key;
			});
		end
		if not data then
			module:log("error", "Unable to set item: %s", err);
			return nil, err;
		end
		return true;
	end
	return setmetatable(get_set, archive);
end
_M.simple_itemstore = simple_itemstore;

return _M;
