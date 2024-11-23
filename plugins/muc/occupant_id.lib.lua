-- Implementation of https://xmpp.org/extensions/xep-0421.html
-- XEP-0421: Anonymous unique occupant identifiers for MUCs

-- (C) 2020 Maxime “pep” Buquet <pep@bouah.net>
-- (C) 2020 Matthew Wild <mwild1@gmail.com>

local uuid = require "prosody.util.uuid";
local hmac_sha256 = require "prosody.util.hashes".hmac_sha256;
local b64encode = require "prosody.util.encodings".base64.encode;

local xmlns_occupant_id = "urn:xmpp:occupant-id:0";

local function get_room_salt(room)
	local salt = room._data.occupant_id_salt;
	if not salt then
		salt = uuid.generate();
		room._data.occupant_id_salt = salt;
	end
	return salt;
end

local function get_occupant_id(room, occupant)
	if occupant.stable_id then
		return occupant.stable_id;
	end

	local salt = get_room_salt(room)

	occupant.stable_id = b64encode(hmac_sha256(occupant.bare_jid, salt));

	return occupant.stable_id;
end

local function update_occupant(event)
	local stanza, room, occupant, dest_occupant = event.stanza, event.room, event.occupant, event.dest_occupant;

	-- "muc-occupant-pre-change" provides "dest_occupant" but not "occupant".
	if dest_occupant ~= nil then
		occupant = dest_occupant;
	end

	-- strip any existing <occupant-id/> tags to avoid forgery
	stanza:remove_children("occupant-id", xmlns_occupant_id);

	local unique_id = get_occupant_id(room, occupant);
	stanza:tag("occupant-id", { xmlns = xmlns_occupant_id, id = unique_id }):up();
end

local function muc_private(event)
	local stanza, room = event.stanza, event.room;
	local occupant = room._occupants[stanza.attr.from];

	update_occupant({
		stanza = stanza,
		room = room,
		occupant = occupant,
	});
end

if module:get_option_boolean("muc_occupant_id", true) then
	module:add_feature(xmlns_occupant_id);
	module:hook("muc-disco#info", function (event)
		event.reply:tag("feature", { var = xmlns_occupant_id }):up();
	end);

	module:hook("muc-broadcast-presence", update_occupant);
	module:hook("muc-occupant-pre-join", update_occupant);
	module:hook("muc-occupant-pre-change", update_occupant);
	module:hook("muc-occupant-groupchat", update_occupant);
	module:hook("muc-private-message", muc_private);
end

return {
	get_room_salt = get_room_salt;
	get_occupant_id = get_occupant_id;
};
