-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "prosody.util.stanza";
local dataform_new = require "prosody.util.dataforms".new;
local usermanager_user_exists  = require "prosody.core.usermanager".user_exists;
local usermanager_create_user_with_role  = require "prosody.core.usermanager".create_user_with_role;
local usermanager_set_password = require "prosody.core.usermanager".create_user;
local usermanager_delete_user  = require "prosody.core.usermanager".delete_user;
local nodeprep = require "prosody.util.encodings".stringprep.nodeprep;
local util_error = require "prosody.util.error";

local additional_fields = module:get_option("additional_registration_fields", {});
local require_encryption = module:get_option_boolean("c2s_require_encryption",
	module:get_option_boolean("require_encryption", true));

local default_role = module:get_option_string("register_ibr_default_role", "prosody:registered");

pcall(function ()
	module:depends("register_limits");
end);

local account_details = module:open_store("account_details");

local field_map = {
	FORM_TYPE = { name = "FORM_TYPE", type = "hidden", value = "jabber:iq:register" };
	username = { name = "username", type = "text-single", label = "Username", required = true };
	password = { name = "password", type = "text-private", label = "Password", required = true };
	nick = { name = "nick", type = "text-single", label = "Nickname" };
	name = { name = "name", type = "text-single", label = "Full Name" };
	first = { name = "first", type = "text-single", label = "Given Name" };
	last = { name = "last", type = "text-single", label = "Family Name" };
	email = { name = "email", type = "text-single", label = "Email" };
	address = { name = "address", type = "text-single", label = "Street" };
	city = { name = "city", type = "text-single", label = "City" };
	state = { name = "state", type = "text-single", label = "State" };
	zip = { name = "zip", type = "text-single", label = "Postal code" };
	phone = { name = "phone", type = "text-single", label = "Telephone number" };
	url = { name = "url", type = "text-single", label = "Webpage" };
	date = { name = "date", type = "text-single", label = "Birth date" };
};

local title = module:get_option_string("registration_title",
	"Creating a new account");
local instructions = module:get_option_string("registration_instructions",
	"Choose a username and password for use with this service.");

local registration_form = dataform_new{
	title = title;
	instructions = instructions;

	field_map.FORM_TYPE;
	field_map.username;
	field_map.password;
};

local registration_query = st.stanza("query", {xmlns = "jabber:iq:register"})
	:tag("instructions"):text(instructions):up()
	:tag("username"):up()
	:tag("password"):up();

for _, field in ipairs(additional_fields) do
	if type(field) == "table" then
		registration_form[#registration_form + 1] = field;
	elseif field_map[field] or field_map[field:sub(1, -2)] then
		if field:match("%+$") then
			field = field:sub(1, -2);
			field_map[field].required = true;
		end

		registration_form[#registration_form + 1] = field_map[field];
		registration_query:tag(field):up();
	else
		module:log("error", "Unknown field %q", field);
	end
end
registration_query:add_child(registration_form:form());

local register_stream_feature = st.stanza("register", {xmlns="http://jabber.org/features/iq-register"}):up();
module:hook("stream-features", function(event)
	local session, features = event.origin, event.features;

	-- Advertise registration to unauthorized clients only.
	if session.type ~= "c2s_unauthed" or (require_encryption and not session.secure) then
		return
	end

	features:add_child(register_stream_feature);
end);

local function parse_response(query)
	local form = query:get_child("x", "jabber:x:data");
	if form then
		return registration_form:data(form);
	else
		local data = {};
		local errors = {};
		for _, field in ipairs(registration_form) do
			local name, required = field.name, field.required;
			if field_map[name] then
				data[name] = query:get_child_text(name);
				if (not data[name] or #data[name] == 0) and required then
					errors[name] = "Required value missing";
				end
			end
		end
		if next(errors) then
			return data, errors;
		end
		return data;
	end
end

-- In-band registration
module:hook("stanza/iq/jabber:iq:register:query", function(event)
	local session, stanza = event.origin, event.stanza;
	local log = session.log or module._log;

	if session.type ~= "c2s_unauthed" then
		log("debug", "Attempted registration when disabled or already authenticated");
		session.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		return true;
	end

	if require_encryption and not session.secure then
		session.send(st.error_reply(stanza, "modify", "policy-violation", "Encryption is required"));
		return true;
	end

	local query = stanza.tags[1];
	if stanza.attr.type == "get" then
		local reply = st.reply(stanza);
		reply:add_child(registration_query);
		session.send(reply);
		return true;
	end

	-- stanza.attr.type == "set"
	if query.tags[1] and query.tags[1].name == "remove" then
		session.send(st.error_reply(stanza, "auth", "registration-required"));
		return true;
	end

	local data, errors = parse_response(query);
	if errors then
		log("debug", "Error parsing registration form:");
		local textual_errors = {};
		for field, err in pairs(errors) do
			log("debug", "Field %q: %s", field, err);
			table.insert(textual_errors, ("%s: %s"):format(field:gsub("^%a", string.upper), err));
		end
		session.send(st.error_reply(stanza, "modify", "not-acceptable", table.concat(textual_errors, "\n")));
		return true;
	end

	local username, password = nodeprep(data.username, true), data.password;
	data.username, data.password = nil, nil;
	local host = module.host;
	if not username or username == "" then
		log("debug", "The requested username is invalid.");
		session.send(st.error_reply(stanza, "modify", "not-acceptable", "The requested username is invalid."));
		return true;
	end

	local user = {
		username = username, password = password, host = host;
		additional = data, ip = session.ip, session = session;
		role = default_role;
		allowed = true;
	};
	module:fire_event("user-registering", user);
	if not user.allowed then
		local error_type, error_condition, reason;
		local err = user.error;
		if err then
			error_type, error_condition, reason = err.type, err.condition, err.text;
		else
			-- COMPAT pre-util.error
			error_type, error_condition, reason = user.error_type, user.error_condition, user.reason;
		end
		log("debug", "Registration disallowed by module: %s", reason or "no reason given");
		session.send(st.error_reply(stanza, error_type or "modify", error_condition or "not-acceptable", reason));
		return true;
	end

	if usermanager_user_exists(username, host) then
		if user.allow_reset == username then
			local ok, err = util_error.coerce(usermanager_set_password(username, password, host));
			if ok then
				module:fire_event("user-password-reset", user);
				session.send(st.reply(stanza)); -- reset ok!
			else
				session.log("error", "Unable to reset password for %s@%s: %s", username, host, err);
				session.send(st.error_reply(stanza, err.type, err.condition, err.text));
			end
			return true;
		else
			log("debug", "Attempt to register with existing username");
			session.send(st.error_reply(stanza, "cancel", "conflict", "The requested username already exists."));
			return true;
		end
	end

	local created, err = usermanager_create_user_with_role(username, password, host, user.role);
	if created then
		data.registered = os.time();
		if not account_details:set(username, data) then
			log("debug", "Could not store extra details");
			usermanager_delete_user(username, host);
			session.send(st.error_reply(stanza, "wait", "internal-server-error", "Failed to write data to disk."));
			return true;
		end
		session.send(st.reply(stanza)); -- user created!
		log("info", "User account created: %s@%s", username, host);
		module:fire_event("user-registered", {
			username = username, host = host, source = "mod_register",
			session = session });
	else
		log("debug", "Could not create user", err);
		session.send(st.error_reply(stanza, "cancel", "feature-not-implemented", err));
	end
	return true;
end);
