-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "prosody.util.stanza";
local is_contact_subscribed = require "prosody.core.rostermanager".is_contact_subscribed;
local jid_bare = require "prosody.util.jid".bare;
local jid_split = require "prosody.util.jid".split;

module:add_feature("jabber:iq:last");

local map = {};

module:hook("pre-presence/bare", function(event)
	local stanza = event.stanza;
	if not(stanza.attr.to) and stanza.attr.type == "unavailable" then
		local t = os.time();
		local s = stanza:get_child_text("status");
		map[event.origin.username] = {s = s, t = t};
	end
end, 10);

module:hook("iq-get/bare/jabber:iq:last:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local username = jid_split(stanza.attr.to) or origin.username;
	if not stanza.attr.to or is_contact_subscribed(username, module.host, jid_bare(stanza.attr.from)) then
		local seconds, text = "0", "";
		if map[username] then
			seconds = string.format("%d", os.difftime(os.time(), map[username].t));
			text = map[username].s;
		end
		origin.send(st.reply(stanza):tag('query', {xmlns='jabber:iq:last', seconds=seconds}):text(text));
	else
		origin.send(st.error_reply(stanza, 'auth', 'forbidden'));
	end
	return true;
end);

module.save = function()
	return {map = map};
end
module.restore = function(data)
	map = data.map or {};
end

