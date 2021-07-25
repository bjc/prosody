local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local usermanager = require "core.usermanager";
local new_id = require "util.id".medium;
local storagemanager = require "core.storagemanager";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local autocreate_on_publish = module:get_option_boolean("autocreate_on_publish", false);
local autocreate_on_subscribe = module:get_option_boolean("autocreate_on_subscribe", false);
local pubsub_disco_name = module:get_option_string("name", "Prosody PubSub Service");
local expose_publisher = module:get_option_boolean("expose_publisher", false)

local service;

local lib_pubsub = module:require "pubsub";

module:depends("disco");
module:add_identity("pubsub", "service", pubsub_disco_name);
module:add_feature("http://jabber.org/protocol/pubsub");

function handle_pubsub_iq(event)
	return lib_pubsub.handle_pubsub_iq(event, service);
end

-- An itemstore supports the following methods:
--   items(): iterator over (id, item)
--   get(id): return item with id
--   set(id, item): set id to item
--   clear(): clear all items
--   resize(n): set new limit and trim oldest items
--   tail(): return the latest item

-- A nodestore supports the following methods:
--   set(node_name, node_data)
--   get(node_name)
--   users(): iterator over (node_name)

local max_max_items = module:get_option_number("pubsub_max_items", 256);

local function tonumber_max_items(n)
	if n == "max" then
		return max_max_items;
	end
	return tonumber(n);
end

local node_store = module:open_store(module.name.."_nodes");

local function create_simple_itemstore(node_config, node_name) --> util.cache like object
	local driver = storagemanager.get_driver(module.host, "pubsub_data");
	local archive = driver:open("pubsub_"..node_name, "archive");
	local max_items = tonumber_max_items(node_config["max_items"]);
	return lib_pubsub.archive_itemstore(archive, max_items, nil, node_name);
end

function simple_broadcast(kind, node, jids, item, actor, node_obj, service) --luacheck: ignore 431/service
	if node_obj then
		if node_obj.config["notify_"..kind] == false then
			return;
		end
	end
	if kind == "retract" then
		kind = "items"; -- XEP-0060 signals retraction in an <items> container
	end

	if item then
		item = st.clone(item);
		item.attr.xmlns = nil; -- Clear the pubsub namespace
		if kind == "items" then
			if node_obj and node_obj.config.include_payload == false then
				item:maptags(function () return nil; end);
			end
			if not expose_publisher then
				item.attr.publisher = nil;
			elseif not item.attr.publisher then
				item.attr.publisher = service.config.normalize_jid(actor);
			end
		end
	end

	local id = new_id();
	local msg_type = node_obj and node_obj.config.notification_type or "headline";
	local message = st.message({ from = module.host, type = msg_type, id = id })
		:tag("event", { xmlns = xmlns_pubsub_event })
			:tag(kind, { node = node });

	if item then
		message:add_child(item);
	end

	local summary;
	if item and item.tags[1] then
		local payload = item.tags[1];
		summary = module:fire_event("pubsub-summary/"..payload.attr.xmlns, {
			kind = kind, node = node, jids = jids, actor = actor, item = item, payload = payload,
		});
	end

	for jid, options in pairs(jids) do
		local new_stanza = st.clone(message);
		if summary and type(options) == "table" and options["pubsub#include_body"] then
			new_stanza:body(summary);
		end
		new_stanza.attr.to = jid;
		module:send(new_stanza);
	end
end

function check_node_config(node, actor, new_config) -- luacheck: ignore 212/node 212/actor
	if (tonumber_max_items(new_config["max_items"]) or 1) > max_max_items then
		return false;
	end
	if new_config["access_model"] ~= "whitelist"
	and new_config["access_model"] ~= "open" then
		return false;
	end
	return true;
end

function is_item_stanza(item)
	return st.is_stanza(item) and item.attr.xmlns == xmlns_pubsub and item.name == "item" and #item.tags == 1;
end

-- Compose a textual representation of Atom payloads
module:hook("pubsub-summary/http://www.w3.org/2005/Atom", function (event)
	local payload = event.payload;
	local title = payload:get_child_text("title");
	local summary = payload:get_child_text("summary");
	if not summary and title then
		local author = payload:find("author/name#");
		summary = title;
		if author then
			summary = author .. " posted " .. summary;
		end
	end
	return summary;
end, -1);

module:hook("iq/host/"..xmlns_pubsub..":pubsub", handle_pubsub_iq);
module:hook("iq/host/"..xmlns_pubsub_owner..":pubsub", handle_pubsub_iq);

local function add_disco_features_from_service(service) --luacheck: ignore 431/service
	for feature in lib_pubsub.get_feature_set(service) do
		module:add_feature(xmlns_pubsub.."#"..feature);
	end
end

module:hook("host-disco-info-node", function (event)
	return lib_pubsub.handle_disco_info_node(event, service);
end);

module:hook("host-disco-items-node", function (event)
	return lib_pubsub.handle_disco_items_node(event, service);
end);


module:hook("host-disco-items", function (event)
	local stanza, reply = event.stanza, event.reply;
	local ok, ret = service:get_nodes(stanza.attr.from);
	if not ok then
		return;
	end
	for node, node_obj in pairs(ret) do
		reply:tag("item", { jid = module.host, node = node, name = node_obj.config.title }):up();
	end
end);

local admin_aff = module:get_option_string("default_admin_affiliation", "owner");
local function get_affiliation(jid)
	local bare_jid = jid_bare(jid);
	if bare_jid == module.host or usermanager.is_admin(bare_jid, module.host) then
		return admin_aff;
	end
end

function get_service()
	return service;
end

function set_service(new_service)
	service = new_service;
	service.config.autocreate_on_publish = autocreate_on_publish;
	service.config.autocreate_on_subscribe = autocreate_on_subscribe;
	service.config.expose_publisher = expose_publisher;
	module.environment.service = service;
	add_disco_features_from_service(service);
end

function module.save()
	return { service = service };
end

function module.restore(data)
	set_service(data.service);
end

function module.load()
	if module.reloading then return; end

	set_service(pubsub.new({
		autocreate_on_publish = autocreate_on_publish;
		autocreate_on_subscribe = autocreate_on_subscribe;
		expose_publisher = expose_publisher;

		node_defaults = {
			["persist_items"] = true;
		};
		nodestore = node_store;
		itemstore = create_simple_itemstore;
		broadcaster = simple_broadcast;
		itemcheck = is_item_stanza;
		check_node_config = check_node_config;
		get_affiliation = get_affiliation;

		normalize_jid = jid_bare;
	}));
end
