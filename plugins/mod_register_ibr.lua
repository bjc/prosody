-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "util.stanza";
local dataform_new = require "util.dataforms".new;
local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_create_user = require "core.usermanager".create_user;
local usermanager_delete_user = require "core.usermanager".delete_user;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local create_throttle = require "util.throttle".create;
local new_cache = require "util.cache".new;
local ip_util = require "util.ip";
local new_ip = ip_util.new_ip;
local match_ip = ip_util.match;
local parse_cidr = ip_util.parse_cidr;

local additional_fields = module:get_option("additional_registration_fields", {});
local require_encryption = module:get_option_boolean("c2s_require_encryption",
	module:get_option_boolean("require_encryption", false));

local account_details = module:open_store("account_details");

local field_map = {
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

local min_seconds_between_registrations = module:get_option_number("min_seconds_between_registrations");
local whitelist_only = module:get_option_boolean("whitelist_registration_only");
local whitelisted_ips = module:get_option_set("registration_whitelist", { "127.0.0.1", "::1" })._items;
local blacklisted_ips = module:get_option_set("registration_blacklist", {})._items;

local throttle_max = module:get_option_number("registration_throttle_max", min_seconds_between_registrations and 1);
local throttle_period = module:get_option_number("registration_throttle_period", min_seconds_between_registrations);
local throttle_cache_size = module:get_option_number("registration_throttle_cache_size", 100);
local blacklist_overflow = module:get_option_boolean("blacklist_on_registration_throttle_overload", false);

local throttle_cache = new_cache(throttle_cache_size, blacklist_overflow and function (ip, throttle)
	if not throttle:peek() then
		module:log("info", "Adding ip %s to registration blacklist", ip);
		blacklisted_ips[ip] = true;
	end
end or nil);

local function check_throttle(ip)
	if not throttle_max then return true end
	local throttle = throttle_cache:get(ip);
	if not throttle then
		throttle = create_throttle(throttle_max, throttle_period);
	end
	throttle_cache:set(ip, throttle);
	return throttle:poll(1);
end

local function ip_in_set(set, ip)
	if set[ip] then
		return true;
	end
	ip = new_ip(ip);
	for in_set in pairs(set) do
		if match_ip(ip, parse_cidr(in_set)) then
			return true;
		end
	end
	return false;
end

-- In-band registration
module:hook("stanza/iq/jabber:iq:register:query", function(event)
	local session, stanza = event.origin, event.stanza;
	local log = session.log or module._log;

	if session.type ~= "c2s_unauthed" then
		log("debug", "Attempted registration when disabled or already authenticated");
		session.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	elseif require_encryption and not session.secure then
		session.send(st.error_reply(stanza, "modify", "policy-violation", "Encryption is required"));
	else
		local query = stanza.tags[1];
		if stanza.attr.type == "get" then
			local reply = st.reply(stanza);
			reply:add_child(registration_query);
			session.send(reply);
		elseif stanza.attr.type == "set" then
			if query.tags[1] and query.tags[1].name == "remove" then
				session.send(st.error_reply(stanza, "auth", "registration-required"));
			else
				local data, errors = parse_response(query);
				if errors then
					log("debug", "Error parsing registration form:");
					for field, err in pairs(errors) do
						log("debug", "Field %q: %s", field, err);
					end
					session.send(st.error_reply(stanza, "modify", "not-acceptable"));
				else
					-- Check that the user is not blacklisted or registering too often
					if not session.ip then
						log("debug", "User's IP not known; can't apply blacklist/whitelist");
					elseif ip_in_set(blacklisted_ips, session.ip) or (whitelist_only and not ip_in_set(whitelisted_ips, session.ip)) then
						session.send(st.error_reply(stanza, "cancel", "not-acceptable", "You are not allowed to register an account."));
						return true;
					elseif throttle_max and not ip_in_set(whitelisted_ips, session.ip) then
						if not check_throttle(session.ip) then
							log("debug", "Registrations over limit for ip %s", session.ip or "?");
							session.send(st.error_reply(stanza, "wait", "not-acceptable"));
							return true;
						end
					end
					local username, password = nodeprep(data.username), data.password;
					data.username, data.password = nil, nil;
					local host = module.host;
					if not username or username == "" then
						log("debug", "The requested username is invalid.");
						session.send(st.error_reply(stanza, "modify", "not-acceptable", "The requested username is invalid."));
						return true;
					end
					local user = { username = username , host = host, additional = data, ip = session.ip, session = session, allowed = true }
					module:fire_event("user-registering", user);
					if not user.allowed then
						log("debug", "Registration disallowed by module");
						session.send(st.error_reply(stanza, "modify", "not-acceptable", "The requested username is forbidden."));
					elseif usermanager_user_exists(username, host) then
						log("debug", "Attempt to register with existing username");
						session.send(st.error_reply(stanza, "cancel", "conflict", "The requested username already exists."));
					else
						-- TODO unable to write file, file may be locked, etc, what's the correct error?
						local error_reply = st.error_reply(stanza, "wait", "internal-server-error", "Failed to write data to disk.");
						if usermanager_create_user(username, password, host) then
							data.registered = os.time();
							if not account_details:set(username, data) then
								log("debug", "Could not store extra details");
								usermanager_delete_user(username, host);
								session.send(error_reply);
								return true;
							end
							session.send(st.reply(stanza)); -- user created!
							log("info", "User account created: %s@%s", username, host);
							module:fire_event("user-registered", {
								username = username, host = host, source = "mod_register",
								session = session });
						else
							log("debug", "Could not create user");
							session.send(error_reply);
						end
					end
				end
			end
		end
	end
	return true;
end);
