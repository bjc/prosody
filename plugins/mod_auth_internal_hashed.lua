-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2010 Jeff Mitchell
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local max = math.max;

local scram_hashers = require "prosody.util.sasl.scram".hashers;
local generate_uuid = require "prosody.util.uuid".generate;
local new_sasl = require "prosody.util.sasl".new;
local hex = require"prosody.util.hex";
local to_hex, from_hex = hex.encode, hex.decode;
local saslprep = require "prosody.util.encodings".stringprep.saslprep;
local secure_equals = require "prosody.util.hashes".equals;

local log = module._log;
local host = module.host;

local accounts = module:open_store("accounts");

local hash_name = module:get_option_enum("password_hash", "SHA-1", "SHA-256");
local get_auth_db = assert(scram_hashers[hash_name], "SCRAM-"..hash_name.." not supported by SASL library");
local scram_name = "scram_"..hash_name:gsub("%-","_"):lower();

-- Default; can be set per-user
local default_iteration_count = module:get_option_integer("default_iteration_count", 10000, 4096);

local tokenauth = module:depends("tokenauth");

-- define auth provider
local provider = {};

function provider.test_password(username, password)
	log("debug", "test password for user '%s'", username);
	local credentials = accounts:get(username) or {};
	if credentials.disabled then
		return nil, "Account disabled.";
	end
	password = saslprep(password);
	if not password then
		return nil, "Password fails SASLprep.";
	end

	if credentials.password ~= nil and string.len(credentials.password) ~= 0 then
		if not secure_equals(saslprep(credentials.password), password) then
			return nil, "Auth failed. Provided password is incorrect.";
		end

		if provider.set_password(username, credentials.password) == nil then
			return nil, "Auth failed. Could not set hashed password from plaintext.";
		else
			return true;
		end
	end

	if credentials.iteration_count == nil or credentials.salt == nil or string.len(credentials.salt) == 0 then
		return nil, "Auth failed. Stored salt and iteration count information is not complete.";
	end

	local valid, stored_key, server_key = get_auth_db(password, credentials.salt, credentials.iteration_count);

	local stored_key_hex = to_hex(stored_key);
	local server_key_hex = to_hex(server_key);

	if valid and secure_equals(stored_key_hex, credentials.stored_key) and secure_equals(server_key_hex, credentials.server_key) then
		return true;
	else
		return nil, "Auth failed. Invalid username, password, or password hash information.";
	end
end

function provider.set_password(username, password)
	log("debug", "set_password for username '%s'", username);
	local account = accounts:get(username);
	if account then
		account.salt = generate_uuid();
		account.iteration_count = max(account.iteration_count or 0, default_iteration_count);
		local valid, stored_key, server_key = get_auth_db(password, account.salt, account.iteration_count);
		if not valid then
			return valid, stored_key;
		end
		local stored_key_hex = to_hex(stored_key);
		local server_key_hex = to_hex(server_key);

		account.stored_key = stored_key_hex
		account.server_key = server_key_hex

		account.password = nil;
		account.updated = os.time();
		return accounts:set(username, account);
	end
	return nil, "Account not available.";
end

function provider.get_account_info(username)
	local account = accounts:get(username);
	if not account then return nil, "Account not available"; end
	return {
		created = account.created;
		password_updated = account.updated;
		enabled = not account.disabled;
	};
end

function provider.user_exists(username)
	local account = accounts:get(username);
	if not account then
		log("debug", "account not found for username '%s'", username);
		return nil, "Auth failed. Invalid username";
	end
	return true;
end

function provider.is_enabled(username) -- luacheck: ignore 212
	local info, err = provider.get_account_info(username);
	if not info then return nil, err; end
	return info.enabled;
end

function provider.enable(username)
	-- TODO map store?
	local account = accounts:get(username);
	account.disabled = nil;
	account.updated = os.time();
	return accounts:set(username, account);
end

function provider.disable(username, meta)
	local account = accounts:get(username);
	account.disabled = true;
	account.disabled_meta = meta;
	account.updated = os.time();
	return accounts:set(username, account);
end

function provider.users()
	return accounts:users();
end

function provider.create_user(username, password)
	local now = os.time();
	if password == nil then
		return accounts:set(username, { created = now; updated = now; disabled = true });
	end
	local salt = generate_uuid();
	local valid, stored_key, server_key = get_auth_db(password, salt, default_iteration_count);
	if not valid then
		return valid, stored_key;
	end
	local stored_key_hex = to_hex(stored_key);
	local server_key_hex = to_hex(server_key);
	return accounts:set(username, {
		stored_key = stored_key_hex, server_key = server_key_hex,
		salt = salt, iteration_count = default_iteration_count,
		created = now, updated = now;
	});
end

function provider.delete_user(username)
	return accounts:set(username, nil);
end

function provider.get_sasl_handler()
	local testpass_authentication_profile = {
		plain_test = function(_, username, password)
			return provider.test_password(username, password), provider.is_enabled(username);
		end,
		[scram_name] = function(_, username)
			local credentials = accounts:get(username);
			if not credentials then return; end
			if credentials.password then
				if provider.set_password(username, credentials.password) == nil then
					return nil, "Auth failed. Could not set hashed password from plaintext.";
				end
				credentials = accounts:get(username);
				if not credentials then return; end
			end

			local stored_key, server_key = credentials.stored_key, credentials.server_key;
			local iteration_count, salt = credentials.iteration_count, credentials.salt;
			stored_key = stored_key and from_hex(stored_key);
			server_key = server_key and from_hex(server_key);
			return stored_key, server_key, iteration_count, salt, not credentials.disabled;
		end;
		oauthbearer = tokenauth.sasl_handler(provider, "oauth2", module:shared("tokenauth/oauthbearer_config"));
	};
	return new_sasl(host, testpass_authentication_profile);
end

module:provides("auth", provider);

