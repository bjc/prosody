-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local valid_whois = {
	moderators = true;
	anyone = true;
};

local function get_whois(room)
	return room._data.whois or "moderators";
end

local function set_whois(room, whois)
	assert(valid_whois[whois], "Invalid whois value")
	if get_whois(room) == whois then return false; end
	room._data.whois = whois;
	if room.save then room:save(true); end
	return true;
end

module:hook("muc-disco#info", function(event)
	event.reply:tag("feature", {var = get_whois(event.room) ~= "anyone" and "muc_semianonymous" or "muc_nonanonymous"}):up();
end);

module:hook("muc-config-form", function(event)
	local whois = get_whois(event.room);
	table.insert(event.form, {
		name = 'muc#roomconfig_whois',
		type = 'list-single',
		label = 'Who May Discover Real JIDs?',
		value = {
			{ value = 'moderators', label = 'Moderators Only', default = whois == 'moderators' },
			{ value = 'anyone',     label = 'Anyone',          default = whois == 'anyone' }
		}
	});
end);

module:hook("muc-config-submitted/muc#roomconfig_whois", function(event)
	if set_whois(event.room, event.value) then
		local code = (new == 'moderators') and "173" or "172";
		event.status_codes[code] = true;
	end
end);

-- Mask 'from' jid as occupant jid if room is anonymous
module:hook("muc-invite", function(event)
	local room, stanza = event.room, event.stanza;
	if get_whois(room) == "moderators" and room:get_default_role(room:get_affiliation(stanza.attr.to)) ~= "moderator" then
		local invite = stanza:get_child("x", "http://jabber.org/protocol/muc#user"):get_child("invite");
		local occupant_jid = room:get_occupant_jid(invite.attr.from);
		if occupant_jid ~= nil then -- FIXME: This will expose real jid if inviter is not in room
			invite.attr.from = occupant_jid;
		end
	end
end, 50);

return {
	get = get_whois;
	set = set_whois;
};
