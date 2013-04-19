-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza"
local jid_split = require "util.jid".split;

local vcards = module:open_store();

module:add_feature("vcard-temp");

local function handle_vcard(event)
	local session, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	if stanza.attr.type == "get" then
		local vCard;
		if to then
			local node, host = jid_split(to);
			vCard = st.deserialize(vcards:get(node)); -- load vCard for user or server
		else
			vCard = st.deserialize(vcards:get(session.username));-- load user's own vCard
		end
		if vCard then
			session.send(st.reply(stanza):add_child(vCard)); -- send vCard!
		else
			session.send(st.error_reply(stanza, "cancel", "item-not-found"));
		end
	else
		if not to then
			if vcards:set(session.username, st.preserialize(stanza.tags[1])) then
				session.send(st.reply(stanza));
			else
				-- TODO unable to write file, file may be locked, etc, what's the correct error?
				session.send(st.error_reply(stanza, "wait", "internal-server-error"));
			end
		else
			session.send(st.error_reply(stanza, "auth", "forbidden"));
		end
	end
	return true;
end

module:hook("iq/bare/vcard-temp:vCard", handle_vcard);
module:hook("iq/host/vcard-temp:vCard", handle_vcard);

-- COMPAT w/0.8
if module:get_option("vcard_compatibility") ~= nil then
	module:log("error", "The vcard_compatibility option has been removed, see"..
		"mod_compat_vcard in prosody-modules if you still need this.");
end
