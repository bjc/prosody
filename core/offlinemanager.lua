-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local datamanager = require "util.datamanager";
local st = require "util.stanza";
local datetime = require "util.datetime";
local ipairs = ipairs;

module "offlinemanager"

function store(node, host, stanza)
	stanza.attr.stamp = datetime.datetime();
	stanza.attr.stamp_legacy = datetime.legacy();
	return datamanager.list_append(node, host, "offline", st.preserialize(stanza));
end

function load(node, host)
	local data = datamanager.list_load(node, host, "offline");
	if not data then return; end
	for k, v in ipairs(data) do
		local stanza = st.deserialize(v);
		stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = host, stamp = stanza.attr.stamp}):up(); -- XEP-0203
		stanza:tag("x", {xmlns = "jabber:x:delay", from = host, stamp = stanza.attr.stamp_legacy}):up(); -- XEP-0091 (deprecated)
		stanza.attr.stamp, stanza.attr.stamp_legacy = nil, nil;
		data[k] = stanza;
	end
	return data;
end

function deleteAll(node, host)
	return datamanager.list_store(node, host, "offline", nil);
end

return _M;
