-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local restrict_persistent = not module:get_option_boolean("muc_room_allow_persistent", true);
module:default_permission(
	restrict_persistent and "prosody:admin" or "prosody:registered",
	":create-persistent-room"
);

local function get_persistent(room)
	return room._data.persistent;
end

local function set_persistent(room, persistent)
	persistent = persistent and true or nil;
	if get_persistent(room) == persistent then return false; end
	room._data.persistent = persistent;
	return true;
end

module:hook("muc-config-form", function(event)
	if not module:may(":create-persistent-room", event.actor) then
		-- Hide config option if this user is not allowed to create persistent rooms
		return;
	end
	table.insert(event.form, {
		name = "muc#roomconfig_persistentroom";
		type = "boolean";
		label = "Persistent (room should remain even when it is empty)";
		desc = "Rooms are automatically deleted when they are empty, unless this option is enabled";
		value = get_persistent(event.room);
	});
end, 100-5);

module:hook("muc-config-submitted/muc#roomconfig_persistentroom", function(event)
	if not module:may(":create-persistent-room", event.actor) then
		return; -- Not allowed
	end
	if set_persistent(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

module:hook("muc-disco#info", function(event)
	event.reply:tag("feature", {var = get_persistent(event.room) and "muc_persistent" or "muc_temporary"}):up();
end);

module:hook("muc-room-destroyed", function(event)
	set_persistent(event.room, false);
end, -100);

return {
	get = get_persistent;
	set = set_persistent;
};
