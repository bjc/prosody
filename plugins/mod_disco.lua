-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local componentmanager_get_children = require "core.componentmanager".get_children;
local st = require "util.stanza"

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
	origin.send(reply);
	return true;
end);
