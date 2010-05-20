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

local function host_handler(host)
	local host_session = hosts[host];
	host_session.events.add_handler("item-added/auth-provider", function (provider)
	        log("debug", "authentication provider = '%s'", config.get(host, "core", "authentication"));
		if config.get(host, "core", "authentication") == provider.name then
			host_session.users = provider;
		end
	end);
	host_session.events.add_handler("item-removed/auth-provider", function (provider)
		if host_session.users == provider then
			userplugins.new_default_provider(host);
		end
	end);
	if host_session.users ~= nil then
		log("debug", "using non-default authentication provider");
	else
		log("debug", "using default authentication provider");
		host_session.users = new_default_provider(host); -- Start with the default usermanager provider
	end
end
prosody.events.add_handler("host-activated", host_handler);
prosody.events.add_handler("component-activated", host_handler);

local function is_cyrus(host) return config.get(host, "core", "sasl_backend") == "cyrus"; end

function validate_credentials(host, username, password, method)
	return hosts[host].users.test_password(username, password);
end

function get_password(username, host)
	return hosts[host].users.get_password(username);
end

function set_password(username, host, password)
	return hosts[host].users.set_password(username, password);
end

function user_exists(username, host)
	return hosts[host].users.user_exists(username);
end

function create_user(username, password, host)
	return hosts[host].users.create_user(username, password);
end

function get_supported_methods(host)
	return hosts[host].users.get_supported_methods();
end

function is_admin(jid, host)
	if host and host ~= "*" then
		return hosts[host].users.is_admin(jid);
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
