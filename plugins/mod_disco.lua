-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local componentmanager_get_children = require "core.componentmanager".get_children;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza"

local disco_items = module:get_option("disco_items") or {};
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

module:add_identity("server", "im", "Prosody"); -- FIXME should be in the non-existing mod_router
module:add_feature("http://jabber.org/protocol/disco#info");
module:add_feature("http://jabber.org/protocol/disco#items");

module:hook("iq/host/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type ~= "get" then return; end
	local node = stanza.tags[1].attr.node;
	if node and node ~= "" then return; end -- TODO fire event?

	local reply = st.reply(stanza):query("http://jabber.org/protocol/disco#info");
	local done = {};
	for _,identity in ipairs(module:get_host_items("identity")) do
		local identity_s = identity.category.."\0"..identity.type;
		if not done[identity_s] then
			reply:tag("identity", identity):up();
			done[identity_s] = true;
		end
	end
	for _,feature in ipairs(module:get_host_items("feature")) do
		if not done[feature] then
			reply:tag("feature", {var=feature}):up();
			done[feature] = true;
		end
	end
	origin.send(reply);
	return true;
end);
module:hook("iq/host/http://jabber.org/protocol/disco#items:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type ~= "get" then return; end
	local node = stanza.tags[1].attr.node;
	if node and node ~= "" then return; end -- TODO fire event?

	local reply = st.reply(stanza):query("http://jabber.org/protocol/disco#items");
	for jid in pairs(componentmanager_get_children(module.host)) do
		reply:tag("item", {jid = jid}):up();
	end
	for _, item in ipairs(disco_items) do
		reply:tag("item", {jid=item[1], name=item[2]}):up();
	end
	origin.send(reply);
	return true;
end);
module:hook("iq/bare/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type ~= "get" then return; end
	local node = stanza.tags[1].attr.node;
	if node and node ~= "" then return; end -- TODO fire event?
	local username = jid_split(stanza.attr.to) or origin.username;
	if not stanza.attr.to or is_contact_subscribed(username, module.host, jid_bare(stanza.attr.from)) then
		local reply = st.reply(stanza):tag('query', {xmlns='http://jabber.org/protocol/disco#info'});
		if not reply.attr.from then reply.attr.from = origin.username.."@"..origin.host; end -- COMPAT To satisfy Psi when querying own account
		module:fire_event("account-disco-info", { session = origin, stanza = reply });
		origin.send(reply);
		return true;
	end
end);
module:hook("iq/bare/http://jabber.org/protocol/disco#items:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type ~= "get" then return; end
	local node = stanza.tags[1].attr.node;
	if node and node ~= "" then return; end -- TODO fire event?
	local username = jid_split(stanza.attr.to) or origin.username;
	if not stanza.attr.to or is_contact_subscribed(username, module.host, jid_bare(stanza.attr.from)) then
		local reply = st.reply(stanza):tag('query', {xmlns='http://jabber.org/protocol/disco#items'});
		if not reply.attr.from then reply.attr.from = origin.username.."@"..origin.host; end -- COMPAT To satisfy Psi when querying own account
		module:fire_event("account-disco-items", { session = origin, stanza = reply });
		origin.send(reply);
		return true;
	end
end);
