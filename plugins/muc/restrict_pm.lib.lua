-- Based on code from mod_muc_restrict_pm in prosody-modules@d82c0383106a
-- by Nicholas George <wirlaburla@worlio.com>

local st = require "prosody.util.stanza";
local muc_util = module:require "muc/util";
local valid_roles = muc_util.valid_roles;

-- COMPAT w/ prosody-modules allow_pm
local compat_map = {
	everyone = "visitor";
	participants = "participant";
	moderators = "moderator";
	members = "affiliated";
};

local function get_allow_pm(room)
	local val = room._data.allow_pm;
	return compat_map[val] or val or "visitor";
end

local function set_allow_pm(room, val)
	if get_allow_pm(room) == val then return false; end
	room._data.allow_pm = val;
	return true;
end

local function get_allow_modpm(room)
	return room._data.allow_modpm or false;
end

local function set_allow_modpm(room, val)
	if get_allow_modpm(room) == val then return false; end
	room._data.allow_modpm = val;
	return true;
end

module:hook("muc-config-form", function(event)
	local pmval = get_allow_pm(event.room);
	table.insert(event.form, {
		name = 'muc#roomconfig_allowpm';
		type = 'list-single';
		label = 'Allow private messages from';
		options = {
			{ value = 'visitor', label = 'Everyone', default = pmval == 'visitor' };
			{ value = 'participant', label = 'Participants', default = pmval == 'participant' };
			{ value = 'moderator', label = 'Moderators', default = pmval == 'moderator' };
			{ value = 'affiliated', label = "Members", default = pmval == "affiliated" };
			{ value = 'none', label = 'No one', default = pmval == 'none' };
		}
	});
	table.insert(event.form, {
		name = '{xmpp:prosody.im}muc#allow_modpm';
		type = 'boolean';
		label = 'Always allow private messages to moderators';
		value = get_allow_modpm(event.room)
	});
end);

module:hook("muc-config-submitted/muc#roomconfig_allowpm", function(event)
	if set_allow_pm(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

module:hook("muc-config-submitted/{xmpp:prosody.im}muc#allow_modpm", function(event)
	if set_allow_modpm(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

local who_restricted = {
	none = "in this group";
	participant = "from guests";
	moderator = "from non-moderators";
	affiliated = "from non-members";
};

module:hook("muc-private-message", function(event)
	local stanza, room = event.stanza, event.room;
	local from_occupant = room:get_occupant_by_nick(stanza.attr.from);
	local to_occupant = room:get_occupant_by_nick(stanza.attr.to);

	-- To self is always okay
	if to_occupant.bare_jid == from_occupant.bare_jid then return; end

	if get_allow_modpm(room) then
		if to_occupant and to_occupant.role == 'moderator'
		or from_occupant and from_occupant.role == "moderator" then
			return; -- Allow to/from moderators
		end
	end

	local pmval = get_allow_pm(room);

	if pmval ~= "none" then
		if pmval == "affiliated" and room:get_affiliation(from_occupant.bare_jid) then
			return; -- Allow from affiliated users
		elseif valid_roles[from_occupant.role] >= valid_roles[pmval] then
			module:log("debug", "Allowing PM: %s(%d) >= %s(%d)", from_occupant.role, valid_roles[from_occupant.role], pmval, valid_roles[pmval]);
			return; -- Allow from a permitted role
		end
	end

	local msg = ("Private messages are restricted %s"):format(who_restricted[pmval]);
	module:log("debug", "Blocking PM from %s %s: %s", from_occupant.role, stanza.attr.from, msg);

	room:route_to_occupant(
		from_occupant,
		st.error_reply(stanza, "cancel", "policy-violation", msg, room.jid)
	);
	return false;
end, 1);

return {
	get_allow_pm = get_allow_pm;
	set_allow_pm = set_allow_pm;
	get_allow_modpm = get_allow_modpm;
	set_allow_modpm = set_allow_modpm;
};
