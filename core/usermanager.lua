-- Prosody IM v0.3
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



require "util.datamanager"
local datamanager = datamanager;
local log = require "util.logger".init("usermanager");
local error = error;
local hashes = require "util.hashes";

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

function user_exists(username, host)
	return datamanager.load(username, host, "accounts") ~= nil; -- FIXME also check for empty credentials
end

function create_user(username, password, host)
	return datamanager.store(username, host, "accounts", {password = password});
end

function get_supported_methods(host)
	local methods = {["PLAIN"] = true}; -- TODO this should be taken from the config
	methods["DIGEST-MD5"] = true;
	return methods;
end

return _M;
