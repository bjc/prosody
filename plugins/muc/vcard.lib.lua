local mod_vcard = module:depends("vcard");

local jid = require "prosody.util.jid";
local st = require "prosody.util.stanza";

-- This must be the same event that mod_vcard hooks
local vcard_event = "iq/bare/vcard-temp:vCard";
local advertise_hashes = module:get_option("muc_avatar_advertise_hashes");

--luacheck: ignore 113/get_room_from_jid

local function get_avatar_hash(room)
	if room.avatar_hash then return room.avatar_hash; end

	local room_node = jid.split(room.jid);
	local hash = mod_vcard.get_avatar_hash(room_node);
	room.avatar_hash = hash;

	return hash;
end

local function send_avatar_hash(room, to)
	local hash = get_avatar_hash(room);
	if not hash and to then return; end -- Don't announce when no avatar

	local presence_vcard = st.presence({to = to, from = room.jid})
		:tag("x", { xmlns = "vcard-temp:x:update" })
			:tag("photo"):text(hash):up();

	if to == nil then
		if not advertise_hashes or advertise_hashes == "presence" then
			room:broadcast_message(presence_vcard);
		end
		if not advertise_hashes or advertise_hashes == "message" then
			room:broadcast_message(st.message({ from = room.jid, type = "groupchat" })
				:tag("x", { xmlns = "http://jabber.org/protocol/muc#user" })
					:tag("status", { code = "104" }));
		end

	else
		module:send(presence_vcard);
	end
end

module:hook(vcard_event, function (event)
	local stanza = event.stanza;
	local to = stanza.attr.to;

	if stanza.attr.type ~= "set" then
		return;
	end

	local room = get_room_from_jid(to);
	if not room then
		return;
	end

	local sender_affiliation = room:get_affiliation(stanza.attr.from);
	if sender_affiliation == "owner" then
		event.allow_vcard_modification = true;
	end
end, 10);

if advertise_hashes ~= "none" then
	module:hook("muc-occupant-joined", function (event)
		send_avatar_hash(event.room, event.stanza.attr.from);
	end);
	module:hook("vcard-updated", function (event)
		local room = get_room_from_jid(event.stanza.attr.to);
		send_avatar_hash(room, nil);
	end);
end

module:hook("muc-disco#info", function (event)
	event.reply:tag("feature", { var = "vcard-temp" }):up();

	table.insert(event.form, {
			name = "muc#roominfo_avatarhash",
			type = "text-multi",
		});
	event.formdata["muc#roominfo_avatarhash"] = get_avatar_hash(event.room);
end);
