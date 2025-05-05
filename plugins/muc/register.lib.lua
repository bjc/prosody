local jid_bare = require "prosody.util.jid".bare;
local jid_resource = require "prosody.util.jid".resource;
local resourceprep = require "prosody.util.encodings".stringprep.resourceprep;
local st = require "prosody.util.stanza";
local dataforms = require "prosody.util.dataforms";

local allow_unaffiliated = module:get_option_boolean("allow_unaffiliated_register", false);

local enforce_nick = module:get_option_boolean("enforce_registered_nickname", false);

-- Whether to include the current registration data as a dataform. Disabled
-- by default currently as it hasn't been widely tested with clients.
local include_reg_form = module:get_option_boolean("muc_registration_include_form", false);

-- reserved_nicks[nick] = jid
local function get_reserved_nicks(room)
	if room._reserved_nicks then
		return room._reserved_nicks;
	end
	module:log("debug", "Refreshing reserved nicks...");
	local reserved_nicks = {};
	for jid, _, data in room:each_affiliation() do
		local nick = data and data.reserved_nickname;
		module:log("debug", "Refreshed for %s: %s", jid, nick);
		if nick then
			reserved_nicks[nick] = jid;
		end
	end
	room._reserved_nicks = reserved_nicks;
	return reserved_nicks;
end

-- Returns the registered nick, if any, for a JID
-- Note: this is just the *nick* part, i.e. the resource of the in-room JID
local function get_registered_nick(room, jid)
	local registered_data = room._affiliation_data[jid];
	if not registered_data then
		return;
	end
	return registered_data.reserved_nickname;
end

-- Returns the JID, if any, that registered a nick (not in-room JID)
local function get_registered_jid(room, nick)
	local reserved_nicks = get_reserved_nicks(room);
	return reserved_nicks[nick];
end

module:hook("muc-set-affiliation", function (event)
	-- Clear reserved nick cache
	event.room._reserved_nicks = nil;
end);

module:hook("muc-disco#info", function (event)
	event.reply:tag("feature", { var = "jabber:iq:register" }):up();
end);

local registration_form = dataforms.new {
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/muc#register" },
	{ name = "muc#register_roomnick", type = "text-single", required = true, label = "Nickname"},
};

module:handle_items("muc-registration-field", function (event)
	module:log("debug", "Adding MUC registration form field: %s", event.item.name);
	table.insert(registration_form, event.item);
end, function (event)
	module:log("debug", "Removing MUC registration form field: %s", event.item.name);
	local removed_field_name = event.item.name;
	for i, field in ipairs(registration_form) do
		if field.name == removed_field_name then
			table.remove(registration_form, i);
			break;
		end
	end
end);

local function enforce_nick_policy(event)
	local origin, stanza = event.origin, event.stanza;
	local room = assert(event.room); -- FIXME
	if not room then return; end

	-- Check if the chosen nickname is reserved
	local requested_nick = jid_resource(stanza.attr.to);
	local reserved_by = get_registered_jid(room, requested_nick);
	if reserved_by and reserved_by ~= jid_bare(stanza.attr.from) then
		module:log("debug", "%s attempted to use nick %s reserved by %s", stanza.attr.from, requested_nick, reserved_by);
		local reply = st.error_reply(stanza, "cancel", "conflict", nil, room.jid):up();
		origin.send(reply);
		return true;
	end

	-- Check if the occupant has a reservation they must use
	if enforce_nick then
		local nick = get_registered_nick(room, jid_bare(stanza.attr.from));
		if nick then
			if event.occupant then
				-- someone is joining, force their nickname to the registered one
				event.occupant.nick = jid_bare(event.occupant.nick) .. "/" .. nick;
			elseif event.dest_occupant.nick ~= jid_bare(event.dest_occupant.nick) .. "/" .. nick then
				-- someone is trying to change nickname to something other than their registered nickname, can't have that
				module:log("debug", "Attempt by %s to join as %s, but their reserved nick is %s", stanza.attr.from, requested_nick, nick);
				local reply = st.error_reply(stanza, "cancel", "not-acceptable", nil, room.jid):up();
				origin.send(reply);
				return true;
			end
		end
	end
end

module:hook("muc-occupant-pre-join", enforce_nick_policy);
module:hook("muc-occupant-pre-change", enforce_nick_policy);

-- Discovering Reserved Room Nickname
-- http://xmpp.org/extensions/xep-0045.html#reservednick
module:hook("muc-disco#info/x-roomuser-item", function (event)
	local nick = get_registered_nick(event.room, jid_bare(event.stanza.attr.from));
	if nick then
		event.reply:tag("identity", { category = "conference", type = "text", name = nick })
	end
end);

local function handle_register_iq(room, origin, stanza)
	local user_jid = jid_bare(stanza.attr.from)
	local affiliation = room:get_affiliation(user_jid);
	if affiliation == "outcast" then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	elseif not (affiliation or allow_unaffiliated) then
		origin.send(st.error_reply(stanza, "auth", "registration-required"));
		return true;
	end
	local reply = st.reply(stanza);
	local registered_nick = get_registered_nick(room, user_jid);
	if stanza.attr.type == "get" then
		reply:query("jabber:iq:register");
		if registered_nick then
			reply:tag("registered"):up();
			reply:tag("username"):text(registered_nick):up();
			if include_reg_form then
				local aff_data = room:get_affiliation_data(user_jid);
				if aff_data then
					reply:add_child(registration_form:form(aff_data, "result"));
				end
			end
			origin.send(reply);
			return true;
		end
		reply:add_child(registration_form:form());
	else -- type == set -- handle registration form
		local query = stanza.tags[1];
		if query:get_child("remove") then
			-- Remove "member" affiliation, but preserve if any other
			local new_affiliation = affiliation ~= "member" and affiliation;
			local ok, err_type, err_condition = room:set_affiliation(true, user_jid, new_affiliation, nil, false);
			if not ok then
				origin.send(st.error_reply(stanza, err_type, err_condition));
				return true;
			end
			origin.send(reply);
			return true;
		end
		local form_tag = query:get_child("x", "jabber:x:data");
		if not form_tag then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Missing dataform"));
			return true;
		end
		local form_type, err = dataforms.get_type(form_tag);
		if not form_type then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Error with form: "..err));
			return true;
		elseif form_type ~= "http://jabber.org/protocol/muc#register" then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Error in form"));
			return true;
		end
		local reg_data, form_err = registration_form:data(form_tag);
		if form_err then
			local errs = {};
			for field, err in pairs(form_err) do
				table.insert(errs, field..": "..err);
			end
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Error in form: "..table.concat(errs)));
			return true;
		end
		-- Is the nickname valid?
		local desired_nick = resourceprep(reg_data["muc#register_roomnick"], true);
		if not desired_nick then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid Nickname"));
			return true;
		end
		-- Is the nickname currently in use by another user?
		local current_occupant = room:get_occupant_by_nick(room.jid.."/"..desired_nick);
		if current_occupant and current_occupant.bare_jid ~= user_jid then
			origin.send(st.error_reply(stanza, "cancel", "conflict"));
			return true;
		end
		-- Is the nickname currently reserved by another user?
		local reserved_by = get_registered_jid(room, desired_nick);
		if reserved_by and reserved_by ~= user_jid then
			origin.send(st.error_reply(stanza, "cancel", "conflict"));
			return true;
		end

		if enforce_nick then
			-- Kick any sessions that are not using this nick before we register it
			local required_room_nick = room.jid.."/"..desired_nick;
			for room_nick, occupant in room:each_occupant() do
				if occupant.bare_jid == user_jid and room_nick ~= required_room_nick then
					room:set_role(true, room_nick, nil); -- Kick (TODO: would be nice to use 333 code)
				end
			end
		end

		-- Checks passed, save the registration
		if registered_nick ~= desired_nick then
			local registration_data = { reserved_nickname = desired_nick };
			module:fire_event("muc-registration-submitted", {
				room = room;
				origin = origin;
				stanza = stanza;
				submitted_data = reg_data;
				affiliation_data = registration_data;
			});
			local ok, err_type, err_condition = room:set_affiliation(true, user_jid, affiliation or "member", nil, registration_data);
			if not ok then
				origin.send(st.error_reply(stanza, err_type, err_condition));
				return true;
			end
			module:log("debug", "Saved nick registration for %s: %s", user_jid, desired_nick);
			origin.send(reply);
			return true;
		end
	end
	origin.send(reply);
	return true;
end

return {
	get_registered_nick = get_registered_nick;
	get_registered_jid = get_registered_jid;
	handle_register_iq = handle_register_iq;
}
