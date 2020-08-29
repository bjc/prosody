-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local function get_name(room)
	return room._data.name;
end

local function set_name(room, name)
	if name == "" then name = nil; end
	if room._data.name == name then return false; end
	room._data.name = name;
	return true;
end

local function insert_name_into_form(event)
	table.insert(event.form, {
		name = "muc#roomconfig_roomname";
		type = "text-single";
		label = "Title";
		value = event.room._data.name;
	});
end

module:hook("muc-disco#info", function(event)
	event.reply:tag("identity", {category="conference", type="text", name=get_name(event.room)}):up();
	insert_name_into_form(event);
end);

module:hook("muc-config-form", insert_name_into_form, 100-1);

module:hook("muc-config-submitted/muc#roomconfig_roomname", function(event)
	if set_name(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

return {
	get = get_name;
	set = set_name;
};
