-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local datetime = require "prosody.util.datetime";
local jid_split = require "prosody.util.jid".split;

local offline_messages = module:open_store("offline", "archive");

module:add_feature("msgoffline");

module:hook("message/offline/handle", function(event)
	local origin, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	local node;
	if to then
		node = jid_split(to)
	else
		node = origin.username;
	end

	local ok = offline_messages:append(node, nil, stanza, os.time(), "");
	if ok then
		module:log("debug", "Saved to offline storage: %s", stanza:top_tag());
	end
	return ok;
end, -1);

module:hook("message/offline/broadcast", function(event)
	local origin = event.origin;
	origin.log("debug", "Broadcasting offline messages");

	local node, host = origin.username, origin.host;

	local data = offline_messages:find(node);
	if not data then return true; end
	for _, stanza, when in data do
		stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = host, stamp = datetime.datetime(when)}):up(); -- XEP-0203
		origin.send(stanza);
	end
	local ok = offline_messages:delete(node);
	if type(ok) == "number" and ok > 0 then
		origin.log("debug", "%d offline messages consumed");
	end
	return true;
end, -1);
