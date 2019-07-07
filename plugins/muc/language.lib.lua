-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local function get_language(room)
	return room._data.language;
end

local function set_language(room, language)
	if language == "" then language = nil; end
	if get_language(room) == language then return false; end
	room._data.language = language;
	return true;
end

local function add_disco_form(event)
	table.insert(event.form, {
		name = "muc#roominfo_lang";
		value = "";
	});
	event.formdata["muc#roominfo_lang"] = get_language(event.room);
end

local function add_form_option(event)
	table.insert(event.form, {
		name = "muc#roomconfig_lang";
		label = "Language tag for room (e.g. 'en', 'de', 'fr' etc.)";
		type = "text-single";
		desc = "Indicate the primary language spoken in this room";
		datatype = "xs:language";
		value = get_language(event.room) or "";
	});
end

module:hook("muc-disco#info", add_disco_form);
module:hook("muc-config-form", add_form_option, 100-3);

module:hook("muc-config-submitted/muc#roomconfig_lang", function(event)
	if set_language(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

return {
	get = get_language;
	set = set_language;
};
