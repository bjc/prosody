-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "prosody.util.stanza";

local muc_util = module:require "muc/util";
local valid_affiliations = muc_util.valid_affiliations;

local function get_members_only(room)
	return room._data.members_only;
end

local function set_members_only(room, members_only)
	members_only = members_only and true or nil;
	if room._data.members_only == members_only then return false; end
	room._data.members_only = members_only;
	if members_only then
		--[[
		If as a result of a change in the room configuration the room type is
		changed to members-only but there are non-members in the room,
		the service MUST remove any non-members from the room and include a
		status code of 322 in the presence unavailable stanzas sent to those users
		as well as any remaining occupants.
		]]
		local occupants_changed = {};
		for _, occupant in room:each_occupant() do
			local affiliation = room:get_affiliation(occupant.bare_jid);
			if valid_affiliations[affiliation or "none"] <= valid_affiliations.none then
				occupant.role = nil;
				room:save_occupant(occupant);
				occupants_changed[occupant] = true;
			end
		end
		local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"})
			:tag("status", {code="322"}):up();
		for occupant in pairs(occupants_changed) do
			room:publicise_occupant_status(occupant, x);
			module:fire_event("muc-occupant-left", {room = room; nick = occupant.nick; occupant = occupant;});
		end
	end
	return true;
end

local function get_allow_member_invites(room)
	return room._data.allow_member_invites;
end

-- Allows members to invite new members into a members-only room,
-- effectively creating an invite-only room
local function set_allow_member_invites(room, allow_member_invites)
	allow_member_invites = allow_member_invites and true or nil;
	if room._data.allow_member_invites == allow_member_invites then return false; end
	room._data.allow_member_invites = allow_member_invites;
	return true;
end

module:hook("muc-disco#info", function(event)
	local members_only_room = not not get_members_only(event.room);
	local members_can_invite = not not get_allow_member_invites(event.room);
	event.reply:tag("feature", {var = members_only_room and "muc_membersonly" or "muc_open"}):up();
	table.insert(event.form, {
		name = "{http://prosody.im/protocol/muc}roomconfig_allowmemberinvites";
		label = "Allow members to invite new members";
		type = "boolean";
		value = members_can_invite;
	});
	table.insert(event.form, {
		name = "muc#roomconfig_allowinvites";
		label = "Allow users to invite other users";
		type = "boolean";
		value = not members_only_room or members_can_invite;
	});
end);


module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_membersonly";
		type = "boolean";
		label = "Only allow members to join";
		desc = "Enable this to only allow access for room owners, admins and members";
		value = get_members_only(event.room);
	});
	table.insert(event.form, {
		name = "{http://prosody.im/protocol/muc}roomconfig_allowmemberinvites";
		type = "boolean";
		label = "Allow members to invite new members";
		value = get_allow_member_invites(event.room);
	});
end, 90-3);

module:hook("muc-config-submitted/muc#roomconfig_membersonly", function(event)
	if set_members_only(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

module:hook("muc-config-submitted/{http://prosody.im/protocol/muc}roomconfig_allowmemberinvites", function(event)
	if set_allow_member_invites(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

-- No affiliation => role of "none"
module:hook("muc-get-default-role", function(event)
	if not event.affiliation and get_members_only(event.room) then
		return false;
	end
end, 2);

-- registration required for entering members-only room
module:hook("muc-occupant-pre-join", function(event)
	local room = event.room;
	if get_members_only(room) then
		local stanza = event.stanza;
		local affiliation = room:get_affiliation(stanza.attr.from);
		if valid_affiliations[affiliation or "none"] <= valid_affiliations.none then
			local reply = st.error_reply(stanza, "auth", "registration-required", nil, room.jid):up();
			event.origin.send(reply);
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
		local inviter_affiliation = room:get_affiliation(stanza.attr.from) or "none";
		local required_affiliation = room._data.allow_member_invites and "member" or "admin";
		if valid_affiliations[inviter_affiliation] < valid_affiliations[required_affiliation] then
			event.origin.send(st.error_reply(stanza, "auth", "forbidden", nil, room.jid));
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
		local invited_unaffiliated = valid_affiliations[affiliation or "none"] <= valid_affiliations.none;
		if invited_unaffiliated then
			local from = stanza:get_child("x", "http://jabber.org/protocol/muc#user")
				:get_child("invite").attr.from;
			module:log("debug", "%s invited %s into members only room %s, granting membership",
				from, invitee, room.jid);
			-- This might fail; ignore for now
			room:set_affiliation(true, invitee, "member", "Invited by " .. from);
			room:save();
		end
	end
end);

return {
	get = get_members_only;
	set = set_members_only;
	get_allow_member_invites = get_allow_member_invites;
	set_allow_member_invites = set_allow_member_invites;
};
