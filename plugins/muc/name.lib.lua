-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local jid_split = require "util.jid".split;

local function get_name(room)
	return room._data.name or jid_split(room.jid);
end

local function set_name(room, name)
	if name == "" or name == (jid_split(room.jid)) then name = nil; end
	if room._data.name == name then return false; end
	room._data.name = name;
	if room.save then room:save(true); end
	return true;
end

module:hook("muc-disco#info", function(event)
	event.reply:tag("identity", {category="conference", type="text", name=get_name(event.room)}):up();
end);

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_roomname";
		type = "text-single";
		label = "Name";
	});
	event.formdata["muc#roomconfig_roomname"] = get_name(event.room) or "";
end);

module:hook("muc-config-submitted/muc#roomconfig_roomname", function(event)
	if set_name(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

return {
	get = get_name;
	set = set_name;
};
