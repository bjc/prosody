-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local muc_util = module:require "muc/util";
local valid_roles, valid_affiliations = muc_util.valid_roles, muc_util.valid_affiliations;

local function get_members_only(room)
	return room._data.members_only;
end

local function set_members_only(room, members_only)
	members_only = members_only and true or nil;
	if room._data.members_only == members_only then return false; end
	room._data.members_only = members_only;
	if room.save then room:save(true); end
	return true;
end

module:hook("muc-disco#info", function(event)
	event.reply:tag("feature", {var = get_members_only(event.room) and "muc_membersonly" or "muc_open"}):up();
end);

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_membersonly";
		type = "boolean";
		label = "Make Room Members-Only?";
		value = get_members_only(event.room);
	});
end);

module:hook("muc-config-submitted", function(event)
	local new = event.fields["muc#roomconfig_membersonly"];
	if new ~= nil and set_members_only(event.room, new) then
		event.status_codes["104"] = true;
	end
end);

-- No affiliation => role of "none"
module:hook("muc-get-default-role", function(event)
	if not event.affiliation and get_members_only(event.room) then
		return false;
	end
end);

-- registration required for entering members-only room
module:hook("muc-occupant-pre-join", function(event)
	local room = event.room;
	if get_members_only(room) then
		local stanza = event.stanza;
		local affiliation = room:get_affiliation(stanza.attr.from);
		if valid_affiliations[affiliation or "none"] <= valid_affiliations.none then
			local reply = st.error_reply(stanza, "auth", "registration-required"):up();
			reply.tags[1].attr.code = "407";
			event.origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
			return true;
		end
	end
end, -5);

-- Invitation privileges in members-only rooms SHOULD be restricted to room admins;
-- if a member without privileges to edit the member list attempts to invite another user
-- the service SHOULD return a <forbidden/> error to the occupant
module:hook("muc-pre-invite", function(event)
	local room = event.room;
	if get_members_only(room) then
		local stanza = event.stanza;
		local affiliation = room:get_affiliation(stanza.attr.from);
		if valid_affiliations[affiliation or "none"] < valid_affiliations.admin then
			event.origin.send(st.error_reply(stanza, "auth", "forbidden"));
			return true;
		end
	end
end);

-- When an invite is sent; add an affiliation for the invitee
module:hook("muc-invite", function(event)
	local room = event.room;
	if get_members_only(room) then
		local stanza = event.stanza;
		local invitee = stanza.attr.to;
		local affiliation = room:get_affiliation(invitee);
		if valid_affiliations[affiliation or "none"] <= valid_affiliations.none then
			local from = stanza:get_child("x", "http://jabber.org/protocol/muc#user")
				:get_child("invite").attr.from;
			module:log("debug", "%s invited %s into members only room %s, granting membership",
				from, invitee, room.jid);
			-- This might fail; ignore for now
			room:set_affiliation(from, invitee, "member", "Invited by " .. from);
		end
	end
end);

return {
	get = get_members_only;
	set = set_members_only;
};
