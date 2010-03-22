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

module "usermanager"

function validate_credentials(host, username, password, method)
	log("debug", "User '%s' is being validated", username);
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
  return (datamanager.load(username, host, "accounts") or {}).password
end

function user_exists(username, host)
	return datamanager.load(username, host, "accounts") ~= nil; -- FIXME also check for empty credentials
end

function create_user(username, password, host)
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
