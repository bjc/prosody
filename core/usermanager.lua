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

local prosody = _G.prosody;

module "usermanager"

local new_default_provider;

local function host_handler(host)
	local host_session = hosts[host];
	host_session.events.add_handler("item-added/auth-provider", function (provider)
		if config.get(host, "core", "authentication") == provider.name then
			host_session.users = provider;
		end
	end);
	host_session.events.add_handler("item-removed/auth-provider", function (provider)
		if host_session.users == provider then
			host_session.users = new_default_provider(host);
		end
	end);
	host_session.users = new_default_provider(host); -- Start with the default usermanager provider
end
prosody.events.add_handler("host-activated", host_handler);
prosody.events.add_handler("component-activated", host_handler);

local function is_cyrus(host) return config.get(host, "core", "sasl_backend") == "cyrus"; end

function new_default_provider(host)
	local provider = { name = "default" };
	
	function provider:test_password(username, password)
		if is_cyrus(host) then return nil, "Legacy auth not supported with Cyrus SASL."; end
		local credentials = datamanager.load(username, host, "accounts") or {};
	
		if password == credentials.password then
			return true;
		else
			return nil, "Auth failed. Invalid username or password.";
		end
	end

	function provider:get_password(username)
		if is_cyrus(host) then return nil, "Passwords unavailable for Cyrus SASL."; end
		return (datamanager.load(username, host, "accounts") or {}).password;
	end
	
	function provider:set_password(username, password)
		if is_cyrus(host) then return nil, "Passwords unavailable for Cyrus SASL."; end
		local account = datamanager.load(username, host, "accounts");
		if account then
			account.password = password;
			return datamanager.store(username, host, "accounts", account);
		end
		return nil, "Account not available.";
	end

	function provider:user_exists(username)
		if not(require_provisioning) and is_cyrus(host) then return true; end
		return datamanager.load(username, host, "accounts") ~= nil; -- FIXME also check for empty credentials
	end

	function provider:create_user(username, password)
		if not(require_provisioning) and is_cyrus(host) then return nil, "Account creation/modification not available with Cyrus SASL."; end
		return datamanager.store(username, host, "accounts", {password = password});
	end

	function provider:get_supported_methods()
		return {["PLAIN"] = true, ["DIGEST-MD5"] = true}; -- TODO this should be taken from the config
	end

	function provider:is_admin(jid)
		local admins = config.get(host, "core", "admins");
		if admins ~= config.get("*", "core", "admins") then
			if type(admins) == "table" then
				jid = jid_bare(jid);
				for _,admin in ipairs(admins) do
					if admin == jid then return true; end
				end
			elseif admins then
				log("error", "Option 'admins' for host '%s' is not a table", host);
			end
		end
		return is_admin(jid); -- Test whether it's a global admin instead
	end
	return provider;
end

function validate_credentials(host, username, password, method)
	return hosts[host].users:test_password(username, password);
end

function get_password(username, host)
	return hosts[host].users:get_password(username);
end

function set_password(username, host, password)
	return hosts[host].users:set_password(username, password);
end

function user_exists(username, host)
	return hosts[host].users:user_exists(username);
end

function create_user(username, password, host)
	return hosts[host].users:create_user(username, password);
end

function get_supported_methods(host)
	return hosts[host].users:get_supported_methods();
end

function is_admin(jid, host)
	if host and host ~= "*" then
		return hosts[host].users:is_admin(jid);
	else -- Test only whether this JID is a global admin
		local admins = config.get("*", "core", "admins");
		if type(admins) == "table" then
			jid = jid_bare(jid);
			for _,admin in ipairs(admins) do
				if admin == jid then return true; end
			end
		elseif admins then
			log("error", "Option 'admins' for host '%s' is not a table", host);
		end
		return nil;
	end
end

_M.new_default_provider = new_default_provider;

return _M;
