local pubsub = require "prosody.util.pubsub";
local st = require "prosody.util.stanza";
local jid_bare = require "prosody.util.jid".bare;
local new_id = require "prosody.util.id".medium;
local storagemanager = require "prosody.core.storagemanager";
local xtemplate = require "prosody.util.xtemplate";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local autocreate_on_publish = module:get_option_boolean("autocreate_on_publish", false);
local autocreate_on_subscribe = module:get_option_boolean("autocreate_on_subscribe", false);
local pubsub_disco_name = module:get_option_string("name", "Prosody PubSub Service");
local service_expose_publisher = module:get_option_boolean("expose_publisher")

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

local max_max_items = module:get_option_integer("pubsub_max_items", 256, 1);

local function tonumber_max_items(n)
	if n == "max" then
		return max_max_items;
	end
	return tonumber(n);
end

for _, field in ipairs(lib_pubsub.node_config_form) do
	if field.var == "pubsub#max_items" then
		field.range_max = max_max_items;
		break;
	end
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
			local node_expose_publisher = service_expose_publisher;
			if node_expose_publisher == nil and node_obj and node_obj.config.itemreply == "publisher" then
				node_expose_publisher = true;
			end
			if not node_expose_publisher then
				item.attr.publisher = nil;
			elseif not item.attr.publisher and actor ~= true then
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
		local payload_type = node_obj and node_obj.config.payload_type or payload.attr.xmlns;
		summary = module:fire_event("pubsub-summary/"..payload_type, {
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
local summary_templates = module:get_option("pubsub_summary_templates", {
	["http://www.w3.org/2005/Atom"] = "{@pubsub:title|and{*{@pubsub:title}*\n\n}}{summary|or{{author/name|and{{author/name} posted }}{title}}}";
})

for pubsub_type, template in pairs(summary_templates) do
	module:hook("pubsub-summary/"..pubsub_type, function (event)
		local payload = event.payload;

		local got_config, node_config = service:get_node_config(event.node, true);
		if got_config then
			payload = st.clone(payload);
			payload.attr["xmlns:pubsub"] = xmlns_pubsub;
			payload.attr["pubsub:node"] = event.node;
			payload.attr["pubsub:title"] = node_config.title;
			payload.attr["pubsub:description"] = node_config.description;
		end

		return xtemplate.render(template, payload, tostring);
	end, -1);
end


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
	for node in pairs(ret) do
		local ok, meta = service:get_node_metadata(node, stanza.attr.from);
		if ok then
			reply:tag("item", { jid = module.host, node = node, name = meta.title }):up();
		end
	end
end);

local admin_aff = module:get_option_enum("default_admin_affiliation", "owner", "publisher", "member", "outcast", "none");

module:default_permission("prosody:admin", ":service-admin");
module:default_permission("prosody:admin", ":create-node");

local function get_affiliation(jid, _, action)
	local bare_jid = jid_bare(jid);
	if bare_jid == module.host then
		-- The host itself (i.e. local modules) is treated as an admin.
		-- Check this first as to avoid sendig a host JID to :may()
		return admin_aff;
	end
	if action == "create" and module:may(":create-node", bare_jid) then
		-- Only one affiliation is allowed to create nodes by default
		return "owner";
	end
	if module:could(":service-admin", bare_jid) then
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
	service.config.expose_publisher = service_expose_publisher;

	service.config.nodestore = node_store;
	service.config.itemstore = create_simple_itemstore;
	service.config.broadcaster = simple_broadcast;
	service.config.itemcheck = is_item_stanza;
	service.config.check_node_config = check_node_config;
	service.config.get_affiliation = get_affiliation;

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
		expose_publisher = service_expose_publisher;

		node_defaults = {
			["persist_items"] = true;
		};
		max_items = max_max_items;
		nodestore = node_store;
		itemstore = create_simple_itemstore;
		broadcaster = simple_broadcast;
		itemcheck = is_item_stanza;
		check_node_config = check_node_config;
		metadata_subset = {
			"title";
			"description";
			"payload_type";
			"access_model";
			"publish_model";
		};
		get_affiliation = get_affiliation;

		jid = module.host;
		normalize_jid = jid_bare;
	}));
end

local function get_service(service_jid)
	return assert(assert(prosody.hosts[service_jid], "Unknown pubsub service").modules.pubsub, "Not a pubsub service").service;
end

module:require("commands").add_commands(get_service);
