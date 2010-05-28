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

local setmetatable = setmetatable;

module "usermanager"

function new_null_provider()
	local function dummy() end;
	return setmetatable({name = "dummyauth"}, { __index = function() return dummy; end });
end

local function host_handler(host)
	local host_session = hosts[host];
	host_session.events.add_handler("item-added/auth-provider", function (event)
		local provider = event.item;
		if config.get(host, "core", "authentication") == nil and provider.name == "default" then
			host_session.users = provider;
		elseif config.get(host, "core", "authentication") == provider.name then
			host_session.users = provider;
		end
		if host_session.users ~= nil and host_session.users.name ~= nil then
			log("debug", "host '%s' now set to use user provider '%s'", host, host_session.users.name);
		end
	end);
	host_session.events.add_handler("item-removed/auth-provider", function (event)
		local provider = event.item;
		if host_session.users == provider then
			host_session.users = new_null_provider();
		end
	end);
end
prosody.events.add_handler("host-activated", host_handler, 100);
prosody.events.add_handler("component-activated", host_handler, 100);

function is_cyrus(host) return config.get(host, "core", "sasl_backend") == "cyrus"; end

function test_password(username, password, host)
	return hosts[host].users.test_password(username, password);
end

function get_password(username, host)
	return hosts[host].users.get_password(username);
end

function set_password(username, password, host)
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

function get_provider(host)
	return hosts[host].users;
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

return _M;
