-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

local function get_password(room)
	return room._data.password;
end

local function set_password(room, password)
	if password == "" then password = nil; end
	if room._data.password == password then return false; end
	room._data.password = password;
	return true;
end

module:hook("muc-disco#info", function(event)
	event.reply:tag("feature", {var = get_password(event.room) and "muc_passwordprotected" or "muc_unsecured"}):up();
end);

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_roomsecret";
		type = "text-private";
		label = "Password";
		value = get_password(event.room) or "";
	});
end, 90-2);

module:hook("muc-config-submitted/muc#roomconfig_roomsecret", function(event)
	if set_password(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

-- Don't allow anyone to join room unless they provide the password
module:hook("muc-occupant-pre-join", function(event)
	local room, stanza = event.room, event.stanza;
	if not get_password(room) then return end
	local muc_x = stanza:get_child("x", "http://jabber.org/protocol/muc");
	if not muc_x then return end
	local password = muc_x:get_child_text("password", "http://jabber.org/protocol/muc");
	if not password or password == "" then password = nil; end
	if get_password(room) ~= password then
		local from, to = stanza.attr.from, stanza.attr.to;
		module:log("debug", "%s couldn't join due to invalid password: %s", from, to);
		local reply = st.error_reply(stanza, "auth", "not-authorized", nil, room.jid):up();
		event.origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
		return true;
	end
end, -20);

-- Add password to outgoing invite
module:hook("muc-invite", function(event)
	local password = get_password(event.room);
	if password then
		local x = event.stanza:get_child("x", "http://jabber.org/protocol/muc#user");
		x:tag("password"):text(password):up();
	end
end);

module:hook("muc-room-pre-create", function (event)
	local stanza, room = event.stanza, event.room;
	local muc_x = stanza:get_child("x", "http://jabber.org/protocol/muc");
	if not muc_x then return end
	local password = muc_x:get_child_text("password", "http://jabber.org/protocol/muc");
	set_password(room, password);
end);

return {
	get = get_password;
	set = set_password;
};
