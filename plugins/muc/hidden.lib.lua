-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local restrict_public = not module:get_option_boolean("muc_room_allow_public", true);
module:default_permission(restrict_public and "prosody:admin" or "prosody:user", ":create-public-room");

local function get_hidden(room)
	return room._data.hidden;
end

local function set_hidden(room, hidden)
	hidden = hidden and true or nil;
	if get_hidden(room) == hidden then return false; end
	room._data.hidden = hidden;
	return true;
end

module:hook("muc-config-form", function(event)
	if not module:may(":create-public-room", event.actor) then
		-- Hide config option if this user is not allowed to create public rooms
		return;
	end
	table.insert(event.form, {
		name = "muc#roomconfig_publicroom";
		type = "boolean";
		label = "Include room information in public lists";
		desc = "Enable this to allow people to find the room";
		value = not get_hidden(event.room);
	});
end, 100-9);

module:hook("muc-config-submitted/muc#roomconfig_publicroom", function(event)
	if not module:may(":create-public-room", event.actor) then
		return; -- Not allowed
	end
	if set_hidden(event.room, not event.value) then
		event.status_codes["104"] = true;
	end
end);

module:hook("muc-disco#info", function(event)
	event.reply:tag("feature", {var = get_hidden(event.room) and "muc_hidden" or "muc_public"}):up();
end);

return {
	get = get_hidden;
	set = set_hidden;
};
