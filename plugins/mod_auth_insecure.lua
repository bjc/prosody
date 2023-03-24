-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 212

local datamanager = require "prosody.util.datamanager";
local new_sasl = require "prosody.util.sasl".new;
local saslprep = require "prosody.util.encodings".stringprep.saslprep;

local host = module.host;
local provider = { name = "insecure" };

assert(module:get_option_string("insecure_open_authentication") == "Yes please, I know what I'm doing!");

function provider.test_password(username, password)
	return true;
end

function provider.set_password(username, password)
	local account = datamanager.load(username, host, "accounts");
	password = saslprep(password);
	if not password then
		return nil, "Password fails SASLprep.";
	end
	if account then
		account.updated = os.time();
		account.password = password;
		return datamanager.store(username, host, "accounts", account);
	end
	return nil, "Account not available.";
end

function provider.user_exists(username)
	return true;
end

function provider.create_user(username, password)
	local now = os.time();
	return datamanager.store(username, host, "accounts", { created = now; updated = now; password = password });
end

function provider.delete_user(username)
	return datamanager.store(username, host, "accounts", nil);
end

function provider.get_sasl_handler()
	local getpass_authentication_profile = {
		plain_test = function(sasl, username, password, realm)
			return true, true;
		end
	};
	return new_sasl(module.host, getpass_authentication_profile);
end

module:add_item("auth-provider", provider);

