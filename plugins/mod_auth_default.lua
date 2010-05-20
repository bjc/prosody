-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2010 Jeff Mitchell
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local datamanager = require "util.datamanager";
local log = require "util.logger".init("usermanager");
local type = type;
local error = error;
local ipairs = ipairs;
local hashes = require "util.hashes";
local jid_bare = require "util.jid".bare;
local config = require "core.configmanager";
local hosts = hosts;

local prosody = _G.prosody;

function new_default_provider(host)
	local provider = { name = "default" };
	
	function provider.test_password(username, password)
		log("debug", "test password for user %s at host %s", username, host);
		if is_cyrus(host) then return nil, "Legacy auth not supported with Cyrus SASL."; end
		local credentials = datamanager.load(username, host, "accounts") or {};
	
		if password == credentials.password then
			return true;
		else
			return nil, "Auth failed. Invalid username or password.";
		end
	end

	function provider.get_password(username)
		log("debug", "get password for user %s at host %s", username, host);
		if is_cyrus(host) then return nil, "Passwords unavailable for Cyrus SASL."; end
		return (datamanager.load(username, host, "accounts") or {}).password;
	end
	
	function provider.set_password(username, password)
		if is_cyrus(host) then return nil, "Passwords unavailable for Cyrus SASL."; end
		local account = datamanager.load(username, host, "accounts");
		if account then
			account.password = password;
			return datamanager.store(username, host, "accounts", account);
		end
		return nil, "Account not available.";
	end

	function provider.user_exists(username)
		if is_cyrus(host) then return true; end
		local account = datamanager.load(username, host, "accounts");
		if not account then
			log("debug", "account not found for username '%s' at host '%s'", username, host);
			return nil, "Auth failed. Invalid username";
		end
		if account.password == nil or string.len(account.password) == 0 then
			log("debug", "account password not set or zero-length for username '%s' at host '%s'", username, host);
			return nil, "Auth failed. Password invalid.";
		end
		return true;
	end

	function provider.create_user(username, password)
		if is_cyrus(host) then return nil, "Account creation/modification not available with Cyrus SASL."; end
		return datamanager.store(username, host, "accounts", {password = password});
	end

	function provider.get_supported_methods()
		return {["PLAIN"] = true, ["DIGEST-MD5"] = true}; -- TODO this should be taken from the config
	end

	function provider.is_admin(jid)
		local admins = config.get(host, "core", "admins");
		if admins ~= config.get("*", "core", "admins") and type(admins) == "table" then
			jid = jid_bare(jid);
			for _,admin in ipairs(admins) do
				if admin == jid then return true; end
			end
		elseif admins then
			log("error", "Option 'admins' for host '%s' is not a table", host);
		end
		return is_admin(jid); -- Test whether it's a global admin instead
	end
	return provider;
end

module:add_item("auth-provider", new_default_provider(module.host));

