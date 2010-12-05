local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local uuid_generate = require "util.uuid".generate;

require "core.modulemanager".load(module.host, "iq");

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";

local service;

local handlers = {};

function handle_pubsub_iq(event)
	local origin, stanza = event.origin, event.stanza;
	local pubsub = stanza.tags[1];
	local action = pubsub.tags[1];
	local handler = handlers[stanza.attr.type.."_"..action.name];
	if handler then
		handler(origin, stanza, action);
		return true;
	end
end

local pubsub_errors = {
	["conflict"] = { "cancel", "conflict" };
	["invalid-jid"] = { "modify", "bad-request", nil, "invalid-jid" };
	["item-not-found"] = { "cancel", "item-not-found" };
	["not-subscribed"] = { "modify", "unexpected-request", nil, "not-subscribed" };
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
	local data = st.stanza("items", { node = node });
	for _, entry in pairs(service:get(node, stanza.attr.from, id)) do
		data:add_child(entry);
	end
	if data then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:add_child(data);
	else
		reply = pubsub_error_reply(stanza, "item-not-found");
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
		until ok;
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("create", { node = node });
	end
	return origin.send(reply);
end

function handlers.set_subscribe(origin, stanza, subscribe)
	local node, jid = subscribe.attr.node, subscribe.attr.jid;
	if jid_bare(jid) ~= jid_bare(stanza.attr.from) then
		return origin.send(pubsub_error_reply(stanza, "invalid-jid"));
	end
	local ok, ret = service:add_subscription(node, stanza.attr.from, jid);
	local reply;
	if ok then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("subscription", {
					node = node,
					jid = jid,
					subscription = "subscribed"
				});
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	return origin.send(reply);
end

function handlers.set_unsubscribe(origin, stanza, unsubscribe)
	local node, jid = unsubscribe.attr.node, unsubscribe.attr.jid;
	if jid_bare(jid) ~= jid_bare(stanza.attr.from) then
		return origin.send(pubsub_error_reply(stanza, "invalid-jid"));
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
	local item = publish:get_child("item");
	local id = (item and item.attr.id) or uuid_generate();
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

function simple_broadcast(node, jids, item)
	local message = st.message({ from = module.host, type = "headline" })
		:tag("event", { xmlns = xmlns_pubsub_event })
			:tag("items", { node = node })
				:add_child(item);
	for jid in pairs(jids) do
		module:log("debug", "Sending notification to %s", jid);
		message.attr.to = jid;
		core_post_stanza(hosts[module.host], message);
	end
end

module:hook("iq/host/http://jabber.org/protocol/pubsub:pubsub", handle_pubsub_iq);

service = pubsub.new({
	broadcaster = simple_broadcast
});
module.environment.service = service;

