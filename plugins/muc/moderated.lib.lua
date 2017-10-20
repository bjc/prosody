-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

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

module:hook("muc-voice-request", function(event)
	if event.occupant.role == "visitor" then
		local form = event.room:get_voice_form_layout()
		local formdata = {
			["muc#jid"] = event.stanza.attr.from;
			["muc#roomnick"] = event.occupant.nick;
		};

		local message = st.message({ type = "normal"; from = event.room.jid }):add_child(form:form(formdata)):up();

		event.room:broadcast(message, function (_, occupant)
			return occupant.role == "moderator";
		end);
	end
end);

module:hook("muc-voice-response", function(event)
	local actor = event.stanza.attr.from;
	local affected_occupant = event.room:get_occupant_by_real_jid(event.fields["muc#jid"]);

	if event.occupant.role ~= "moderator" then
		return;
	end

	if not event.fields["muc#request_allow"] then
		return;
	end

	if not affected_occupant then
		return;
	end

	if affected_occupant.role == "visitor" then
		event.room:set_role(actor, affected_occupant.nick, "participant", "Voice granted");
	end
end);


return {
	get = get_moderated;
	set = set_moderated;
};
