-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
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

local require_provisioning = config.get("*", "core", "cyrus_require_provisioning") or false;

module "usermanager"

local function is_cyrus(host) return config.get(host, "core", "sasl_backend") == "cyrus"; end

function validate_credentials(host, username, password, method)
	log("debug", "User '%s' is being validated", username);
	if is_cyrus(host) then return nil, "Legacy auth not supported with Cyrus SASL."; end
	local credentials = datamanager.load(username, host, "accounts") or {};

	if method == nil then method = "PLAIN"; end
	if method == "PLAIN" and credentials.password then -- PLAIN, do directly
		if password == credentials.password then
			return true;
		else
			return nil, "Auth failed. Invalid username or password.";
		end
  end
	-- must do md5
	-- make credentials md5
	local pwd = credentials.password;
	if not pwd then pwd = credentials.md5; else pwd = hashes.md5(pwd, true); end
	-- make password md5
	if method == "PLAIN" then
		password = hashes.md5(password or "", true);
	elseif method ~= "DIGEST-MD5" then
		return nil, "Unsupported auth method";
	end
	-- compare
	if password == pwd then
		return true;
	else
		return nil, "Auth failed. Invalid username or password.";
	end
end

function get_password(username, host)
	if is_cyrus(host) then return nil, "Passwords unavailable for Cyrus SASL."; end
	return (datamanager.load(username, host, "accounts") or {}).password
end
function set_password(username, host, password)
	if is_cyrus(host) then return nil, "Passwords unavailable for Cyrus SASL."; end
	local account = datamanager.load(username, host, "accounts");
	if account then
		account.password = password;
		return datamanager.store(username, host, "accounts", account);
	end
	return nil, "Account not available.";
end

function user_exists(username, host)
	if not(require_provisioning) and is_cyrus(host) then return true; end
	return datamanager.load(username, host, "accounts") ~= nil; -- FIXME also check for empty credentials
end

function create_user(username, password, host)
	if not(require_provisioning) and is_cyrus(host) then return nil, "Account creation/modification not available with Cyrus SASL."; end
	return datamanager.store(username, host, "accounts", {password = password});
end

function get_supported_methods(host)
	return {["PLAIN"] = true, ["DIGEST-MD5"] = true}; -- TODO this should be taken from the config
end

function is_admin(jid, host)
	host = host or "*";
	local admins = config.get(host, "core", "admins");
	if host ~= "*" and admins == config.get("*", "core", "admins") then
		return nil;
	end
	if type(admins) == "table" then
		jid = jid_bare(jid);
		for _,admin in ipairs(admins) do
			if admin == jid then return true; end
		end
	elseif admins then log("warn", "Option 'admins' for host '%s' is not a table", host); end
	return nil;
end

return _M;
