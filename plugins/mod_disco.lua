-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local get_children = require "prosody.core.hostmanager".get_children;
local is_contact_subscribed = require "prosody.core.rostermanager".is_contact_subscribed;
local jid_split = require "prosody.util.jid".split;
local jid_bare = require "prosody.util.jid".bare;
local st = require "prosody.util.stanza"
local calculate_hash = require "prosody.util.caps".calculate_hash;

local expose_admins = module:get_option_boolean("disco_expose_admins", false);

local disco_items = module:get_option_array("disco_items", {})
do -- validate disco_items
	for _, item in ipairs(disco_items) do
		local err;
		if type(item) ~= "table" then
			err = "item is not a table";
		elseif type(item[1]) ~= "string" then
			err = "item jid is not a string";
		elseif item[2] and type(item[2]) ~= "string" then
			err = "item name is not a string";
		end
		if err then
			module:log("error", "option disco_items is malformed: %s", err);
			disco_items = {}; -- TODO clean up data instead of removing it?
			break;
		end
	end
end

if module:get_host_type() == "local" then
	module:add_identity("server", "im", module:get_option_string("name", "Prosody")); -- FIXME should be in the nonexisting mod_router
end
module:add_feature("http://jabber.org/protocol/disco#info");
module:add_feature("http://jabber.org/protocol/disco#items");

-- Generate and cache disco result and caps hash
local _cached_server_disco_info, _cached_server_caps_feature, _cached_server_caps_hash;
local function build_server_disco_info()
	local query = st.stanza("query", { xmlns = "http://jabber.org/protocol/disco#info" });
	local done = {};
	for _,identity in ipairs(module:get_host_items("identity")) do
		local identity_s = identity.category.."\0"..identity.type;
		if not done[identity_s] then
			query:tag("identity", identity):up();
			done[identity_s] = true;
		end
	end
	for _,feature in ipairs(module:get_host_items("feature")) do
		if not done[feature] then
			query:tag("feature", {var=feature}):up();
			done[feature] = true;
		end
	end
	for _,extension in ipairs(module:get_host_items("extension")) do
		if not done[extension] then
			query:add_child(extension);
			done[extension] = true;
		end
	end
	_cached_server_disco_info = query;
	_cached_server_caps_hash = calculate_hash(query);
	_cached_server_caps_feature = st.stanza("c", {
		xmlns = "http://jabber.org/protocol/caps";
		hash = "sha-1";
		node = "http://prosody.im";
		ver = _cached_server_caps_hash;
	});
end

local function clear_disco_cache()
	_cached_server_disco_info, _cached_server_caps_feature, _cached_server_caps_hash = nil, nil, nil;
end
local function get_server_disco_info()
	if not _cached_server_disco_info then build_server_disco_info(); end
	return _cached_server_disco_info;
end
local function get_server_caps_feature()
	if not _cached_server_caps_feature then build_server_disco_info(); end
	return _cached_server_caps_feature;
end
local function get_server_caps_hash()
	if not _cached_server_caps_hash then build_server_disco_info(); end
	return _cached_server_caps_hash;
end

module:hook("item-added/identity", clear_disco_cache);
module:hook("item-added/feature", clear_disco_cache);
module:hook("item-added/extension", clear_disco_cache);
module:hook("item-removed/identity", clear_disco_cache);
module:hook("item-removed/feature", clear_disco_cache);
module:hook("item-removed/extension", clear_disco_cache);

-- Handle disco requests to the server
module:hook("iq-get/host/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local node = stanza.tags[1].attr.node;
	if node and node ~= "" and node ~= "http://prosody.im#"..get_server_caps_hash() then
		local reply = st.reply(stanza):tag('query', {xmlns='http://jabber.org/protocol/disco#info', node=node});
		local node_event = { origin = origin, stanza = stanza, reply = reply, node = node, exists = false};
		local ret = module:fire_event("host-disco-info-node", node_event);
		if ret ~= nil then return ret; end
		if node_event.exists then
			origin.send(reply);
		else
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Node does not exist"));
		end
		return true;
	end
	local reply_query = get_server_disco_info();
	reply_query.attr.node = node;
	local reply = st.reply(stanza):add_child(reply_query);
	origin.send(reply);
	return true;
end);

module:hook("iq-get/host/http://jabber.org/protocol/disco#items:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local node = stanza.tags[1].attr.node;
	if node and node ~= "" then
		local reply = st.reply(stanza):tag('query', {xmlns='http://jabber.org/protocol/disco#items', node=node});
		local node_event = { origin = origin, stanza = stanza, reply = reply, node = node, exists = false};
		local ret = module:fire_event("host-disco-items-node", node_event);
		if ret ~= nil then return ret; end
		if node_event.exists then
			origin.send(reply);
		else
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Node does not exist"));
		end
		return true;
	end
	local reply = st.reply(stanza):query("http://jabber.org/protocol/disco#items");
	local ret = module:fire_event("host-disco-items", { origin = origin, stanza = stanza, reply = reply });
	if ret ~= nil then return ret; end
	for jid, name in pairs(get_children(module.host)) do
		reply:tag("item", {jid = jid, name = name~=true and name or nil}):up();
	end
	for _, item in ipairs(disco_items) do
		reply:tag("item", {jid=item[1], name=item[2]}):up();
	end
	origin.send(reply);
	return true;
end);

-- Handle caps stream feature
module:hook("stream-features", function (event)
	if event.origin.type == "c2s" or event.origin.type == "c2s_unbound" then
		event.features:add_child(get_server_caps_feature());
	end
end);

module:hook("s2s-stream-features", function (event)
	if event.origin.type == "s2sin" then
		event.features:add_child(get_server_caps_feature());
	end
end);

module:default_permission("prosody:admin", ":be-discovered-admin");

-- Handle disco requests to user accounts
if module:get_host_type() ~= "local" then	return end -- skip for components
module:hook("iq-get/bare/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local node = stanza.tags[1].attr.node;
	local username = jid_split(stanza.attr.to) or origin.username;
	local target_is_admin = module:may(":be-discovered-admin", stanza.attr.to or origin.full_jid);
	if not stanza.attr.to or (expose_admins and target_is_admin) or is_contact_subscribed(username, module.host, jid_bare(stanza.attr.from)) then
		if node and node ~= "" then
			local reply = st.reply(stanza):tag('query', {xmlns='http://jabber.org/protocol/disco#info', node=node});
			reply:tag("feature", { var = "http://jabber.org/protocol/disco#info" }):up();
			reply:tag("feature", { var = "http://jabber.org/protocol/disco#items" }):up();
			if not reply.attr.from then reply.attr.from = origin.username.."@"..origin.host; end -- COMPAT To satisfy Psi when querying own account
			local node_event = { origin = origin, stanza = stanza, reply = reply, node = node, exists = false};
			local ret = module:fire_event("account-disco-info-node", node_event);
			if ret ~= nil then return ret; end
			if node_event.exists then
				origin.send(reply);
			else
				origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Node does not exist"));
			end
			return true;
		end
		local reply = st.reply(stanza):tag('query', {xmlns='http://jabber.org/protocol/disco#info'});
		if not reply.attr.from then reply.attr.from = origin.username.."@"..origin.host; end -- COMPAT To satisfy Psi when querying own account
		if target_is_admin then
			reply:tag('identity', {category='account', type='admin'}):up();
		elseif prosody.hosts[module.host].users.name == "anonymous" then
			reply:tag('identity', {category='account', type='anonymous'}):up();
		else
			reply:tag('identity', {category='account', type='registered'}):up();
		end
		reply:tag("feature", { var = "http://jabber.org/protocol/disco#info" }):up();
		reply:tag("feature", { var = "http://jabber.org/protocol/disco#items" }):up();
		module:fire_event("account-disco-info", { origin = origin, reply = reply });
		origin.send(reply);
		return true;
	end
end);

module:hook("iq-get/bare/http://jabber.org/protocol/disco#items:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local node = stanza.tags[1].attr.node;
	local username = jid_split(stanza.attr.to) or origin.username;
	if not stanza.attr.to or is_contact_subscribed(username, module.host, jid_bare(stanza.attr.from)) then
		if node and node ~= "" then
			local reply = st.reply(stanza):tag('query', {xmlns='http://jabber.org/protocol/disco#items', node=node});
			if not reply.attr.from then reply.attr.from = origin.username.."@"..origin.host; end -- COMPAT To satisfy Psi when querying own account
			local node_event = { origin = origin, stanza = stanza, reply = reply, node = node, exists = false};
			local ret = module:fire_event("account-disco-items-node", node_event);
			if ret ~= nil then return ret; end
			if node_event.exists then
				origin.send(reply);
			else
				origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Node does not exist"));
			end
			return true;
		end
		local reply = st.reply(stanza):tag('query', {xmlns='http://jabber.org/protocol/disco#items'});
		if not reply.attr.from then reply.attr.from = origin.username.."@"..origin.host; end -- COMPAT To satisfy Psi when querying own account
		module:fire_event("account-disco-items", { origin = origin, stanza = stanza, reply = reply });
		origin.send(reply);
		return true;
	end
end);

