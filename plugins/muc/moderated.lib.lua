-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local function get_moderated(room)
	return room._data.moderated;
end

local function set_moderated(room, moderated)
	moderated = moderated and true or nil;
	if get_moderated(room) == moderated then return false; end
	room._data.moderated = moderated;
	return true;
end

module:hook("muc-disco#info", function(event)
	event.reply:tag("feature", {var = get_moderated(event.room) and "muc_moderated" or "muc_unmoderated"}):up();
end);

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_moderatedroom";
		type = "boolean";
		label = "Make Room Moderated?";
		value = get_moderated(event.room);
	});
end, 100-4);

module:hook("muc-config-submitted/muc#roomconfig_moderatedroom", function(event)
	if set_moderated(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

module:hook("muc-get-default-role", function(event)
	if event.affiliation == nil then
		if get_moderated(event.room) then
			return "visitor"
		end
	end
end, 1);

return {
	get = get_moderated;
	set = set_moderated;
};
