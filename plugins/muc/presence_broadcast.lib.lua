-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

local valid_roles = { "visitor", "participant", "moderator" };
local default_broadcast = {
	none = true;
	visitor = true;
	participant = true;
	moderator = true;
};

local function get_presence_broadcast(room)
	return room._data.presence_broadcast or default_broadcast;
end

local function set_presence_broadcast(room, broadcast_roles)
	broadcast_roles = broadcast_roles or default_broadcast;

	-- Ensure that unavailable presence is always sent when role changes to none
	broadcast_roles.none = true;

	local changed = false;
	local old_broadcast_roles = get_presence_broadcast(room);
	for _, role in ipairs(valid_roles) do
		if old_broadcast_roles[role] ~= broadcast_roles[role] then
			changed = true;
		end
	end

	if not changed then return false; end

	room._data.presence_broadcast = broadcast_roles;

	for _, occupant in room:each_occupant() do
		local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user";});
		local role = occupant.role or "none";
		if broadcast_roles[role] and not old_broadcast_roles[role] then
			-- Presence broadcast is now enabled, so announce existing user
			room:publicise_occupant_status(occupant, x);
		elseif old_broadcast_roles[role] and not broadcast_roles[role] then
			-- Presence broadcast is now disabled, so mark existing user as unavailable
			room:publicise_occupant_status(occupant, x, nil, nil, nil, nil, true);
		end
	end

	return true;
end

module:hook("muc-config-form", function(event)
	local values = {};
	for role, value in pairs(get_presence_broadcast(event.room)) do
		if value then
			values[#values + 1] = role;
		end
	end

	table.insert(event.form, {
		name = "muc#roomconfig_presencebroadcast";
		type = "list-multi";
		label = "Only show participants with roles:";
		value = values;
		options = valid_roles;
	});
end, 70-7);

module:hook("muc-config-submitted/muc#roomconfig_presencebroadcast", function(event)
	local broadcast_roles = {};
	for _, role in ipairs(event.value) do
		broadcast_roles[role] = true;
	end
	if set_presence_broadcast(event.room, broadcast_roles) then
		event.status_codes["104"] = true;
	end
end);

return {
	get = get_presence_broadcast;
	set = set_presence_broadcast;
};
