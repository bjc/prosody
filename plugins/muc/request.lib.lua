-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "prosody.util.stanza";
local jid_resource = require "prosody.util.jid".resource;

module:hook("muc-disco#info", function(event)
	event.reply:tag("feature", {var = "http://jabber.org/protocol/muc#request"}):up();
end);

local voice_request_form = require "prosody.util.dataforms".new({
	title = "Voice Request";
	{
		name = "FORM_TYPE";
		type = "hidden";
		value = "http://jabber.org/protocol/muc#request";
	},
	{
		name = "muc#jid";
		type = "jid-single";
		label = "User ID";
		desc = "The user's JID (address)";
	},
	{
		name = "muc#roomnick";
		type = "text-single";
		label = "Room nickname";
		desc = "The user's nickname within the room";
	},
	{
		name = "muc#role";
		type = "list-single";
		label = "Requested role";
		value = "participant";
		options = {
			"none",
			"visitor",
			"participant",
			"moderator",
		};
	},
	{
		name = "muc#request_allow";
		type = "boolean";
		label = "Grant voice to this person?";
		desc = "Specify whether this person is able to speak in a moderated room";
		value = false;
	}
});

local function handle_request(room, origin, stanza, form)
	local occupant = room:get_occupant_by_real_jid(stanza.attr.from);
	local fields = voice_request_form:data(form);
	local event = {
		room = room;
		origin = origin;
		stanza = stanza;
		fields = fields;
		occupant = occupant;
	};
	if occupant.role == "moderator" then
		module:log("debug", "%s responded to a voice request in %s", jid_resource(occupant.nick), room.jid);
		module:fire_event("muc-voice-response", event);
	else
		module:log("debug", "%s requested voice in %s", jid_resource(occupant.nick), room.jid);
		module:fire_event("muc-voice-request", event);
	end
end

module:hook("muc-voice-request", function(event)
	if event.occupant.role == "visitor" then
		local nick = jid_resource(event.occupant.nick);
		local formdata = {
			["muc#jid"] = event.stanza.attr.from;
			["muc#roomnick"] = nick;
		};

		local message = st.message({ type = "normal"; from = event.room.jid })
			:add_child(voice_request_form:form(formdata));

		event.room:broadcast(message, function (_, occupant)
			return occupant.role == "moderator";
		end);
	end
end);

module:hook("muc-voice-response", function(event)
	local actor = event.stanza.attr.from;
	local affected_occupant = event.room:get_occupant_by_real_jid(event.fields["muc#jid"]);
	local occupant = event.occupant;

	if occupant.role ~= "moderator" then
		module:log("debug", "%s tried to grant voice but wasn't a moderator", jid_resource(occupant.nick));
		return;
	end

	if not event.fields["muc#request_allow"] then
		module:log("debug", "%s did not grant voice", jid_resource(occupant.nick));
		return;
	end

	if not affected_occupant then
		module:log("debug", "%s tried to grant voice to unknown occupant %s",
			jid_resource(occupant.nick), event.fields["muc#jid"]);
		return;
	end

	if affected_occupant.role ~= "visitor" then
		module:log("debug", "%s tried to grant voice to %s but they already have it",
			jid_resource(occupant.nick), jid_resource(occupant.jid));
		return;
	end

	module:log("debug", "%s granted voice to %s", jid_resource(event.occupant.nick), jid_resource(occupant.jid));
	local ok, errtype, err = event.room:set_role(actor, affected_occupant.nick, "participant", "Voice granted");

	if not ok then
		module:log("debug", "Error granting voice: %s", err or errtype);
		event.origin.send(st.error_reply(event.stanza, errtype, err));
	end
end);


return {
	handle_request = handle_request;
};
