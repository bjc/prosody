-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local function get_description(room)
	return room._data.description;
end

local function set_description(room, description)
	if description == "" then description = nil; end
	if get_description(room) == description then return false; end
	room._data.description = description;
	if room.save then room:save(true); end
	return true;
end

local function add_form_option(event)
	table.insert(event.form, {
		name = "muc#roomconfig_roomdesc";
		type = "text-single";
		label = "Description";
		value = get_description(event.room) or "";
	});
end
module:hook("muc-disco#info", add_form_option);
module:hook("muc-config-form", add_form_option);

module:hook("muc-config-submitted", function(event)
	local new = event.fields["muc#roomconfig_roomdesc"];
	if new ~= nil and set_description(event.room, new) then
		event.status_codes["104"] = true;
	end
end);

return {
	get = get_description;
	set = set_description;
};
