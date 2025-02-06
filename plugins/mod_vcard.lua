-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local base64 = require "prosody.util.encodings".base64;
local jid = require "prosody.util.jid";
local sha1 = require "prosody.util.hashes".sha1;
local st = require "prosody.util.stanza"
local jid_split = require "prosody.util.jid".split;

local store_name = module:get_option_string("vcard_store_name");

local is_component = module:get_host_type() == "component";
if is_component and not store_name and module:get_option_string("component_module") == "muc" then
	store_name = "vcard_muc";
end

local vcards = module:open_store(store_name);

module:add_feature("vcard-temp");


local function handle_vcard(event)
	local session, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	if stanza.attr.type == "get" then
		local vCard;
		if to then
			local node = jid_split(to);
			vCard = st.deserialize(vcards:get(node)); -- load vCard for user or server
		elseif not is_component then
			vCard = st.deserialize(vcards:get(session.username));-- load user's own vCard
		end
		if vCard then
			session.send(st.reply(stanza):add_child(vCard)); -- send vCard!
		else
			session.send(st.error_reply(stanza, "cancel", "item-not-found"));
		end
	else -- stanza.attr.type == "set"
		if not to or (is_component and event.allow_vcard_modification) then
			local node = is_component and jid.node(stanza.attr.to) or session.username;
			if vcards:set(node, st.preserialize(stanza.tags[1])) then
				session.send(st.reply(stanza));
				module:fire_event("vcard-updated", event);
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

function get_avatar_hash(username)
	local vcard = st.deserialize(vcards:get(username));
	if not vcard then return end
	local photo = vcard:get_child("PHOTO");
	if not photo then return end

	local photo_b64 = photo:get_child_text("BINVAL");
	local photo_raw = photo_b64 and base64.decode(photo_b64);
	return (sha1(photo_raw, true));
end
