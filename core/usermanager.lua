-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local modulemanager = require "core.modulemanager";
local log = require "util.logger".init("usermanager");
local type = type;
local it = require "util.iterators";
local jid_prep, jid_split = require "util.jid".prep, require "util.jid".split;
local config = require "core.configmanager";
local sasl_new = require "util.sasl".new;
local storagemanager = require "core.storagemanager";
local set = require "util.set";

local prosody = _G.prosody;
local hosts = prosody.hosts;

local setmetatable = setmetatable;

local default_provider = "internal_hashed";

local _ENV = nil;
-- luacheck: std none

local function new_null_provider()
	local function dummy() return nil, "method not implemented"; end;
	local function dummy_get_sasl_handler() return sasl_new(nil, {}); end
	return setmetatable({name = "null", get_sasl_handler = dummy_get_sasl_handler}, {
		__index = function(self, method) return dummy; end --luacheck: ignore 212
	});
end

local global_admins_config = config.get("*", "admins");
if type(global_admins_config) ~= "table" then
	global_admins_config = nil; -- TODO: factor out moduleapi magic config handling and use it here
end
local global_admins = set.new(global_admins_config) / jid_prep;

local admin_role = { ["prosody:admin"] = true };
local global_authz_provider = {
	get_user_roles = function (user) end; --luacheck: ignore 212/user
	get_jids_with_role = function (role)
		if role ~= "prosody:admin" then return {}; end
		return it.to_array(global_admins);
	end;
	set_user_roles = function (user, roles) end; -- luacheck: ignore 212
	set_jid_roles = function (jid, roles) end; -- luacheck: ignore 212

	get_user_default_role = function (user) end; -- luacheck: ignore 212
	get_users_with_role = function (role_name) end; -- luacheck: ignore 212
	get_jid_role = function (jid) end; -- luacheck: ignore 212
	set_jid_role = function (jid) end; -- luacheck: ignore 212
	add_default_permission = function (role_name, action, policy) end; -- luacheck: ignore 212
	get_role_by_name = function (role_name) end; -- luacheck: ignore 212
};

local provider_mt = { __index = new_null_provider() };

local function initialize_host(host)
	local host_session = hosts[host];

	local authz_provider_name = config.get(host, "authorization") or "internal";

	local authz_mod = modulemanager.load(host, "authz_"..authz_provider_name);
	host_session.authz = authz_mod or global_authz_provider;

	if host_session.type ~= "local" then return; end

	host_session.events.add_handler("item-added/auth-provider", function (event)
		local provider = event.item;
		local auth_provider = config.get(host, "authentication") or default_provider;
		if config.get(host, "anonymous_login") then
			log("error", "Deprecated config option 'anonymous_login'. Use authentication = 'anonymous' instead.");
			auth_provider = "anonymous";
		end -- COMPAT 0.7
		if provider.name == auth_provider then
			host_session.users = setmetatable(provider, provider_mt);
		end
		if host_session.users ~= nil and host_session.users.name ~= nil then
			log("debug", "Host '%s' now set to use user provider '%s'", host, host_session.users.name);
		end
	end);
	host_session.events.add_handler("item-removed/auth-provider", function (event)
		local provider = event.item;
		if host_session.users == provider then
			host_session.users = new_null_provider();
		end
	end);
	host_session.users = new_null_provider(); -- Start with the default usermanager provider
	local auth_provider = config.get(host, "authentication") or default_provider;
	if config.get(host, "anonymous_login") then auth_provider = "anonymous"; end -- COMPAT 0.7
	if auth_provider ~= "null" then
		modulemanager.load(host, "auth_"..auth_provider);
	end

end;
prosody.events.add_handler("host-activated", initialize_host, 100);

local function test_password(username, host, password)
	return hosts[host].users.test_password(username, password);
end

local function get_password(username, host)
	return hosts[host].users.get_password(username);
end

local function set_password(username, password, host, resource)
	local ok, err = hosts[host].users.set_password(username, password);
	if ok then
		prosody.events.fire_event("user-password-changed", { username = username, host = host, resource = resource });
	end
	return ok, err;
end

local function get_account_info(username, host)
	local method = hosts[host].users.get_account_info;
	if not method then return nil, "method-not-supported"; end
	return method(username);
end

local function user_exists(username, host)
	if hosts[host].sessions[username] then return true; end
	return hosts[host].users.user_exists(username);
end

local function create_user(username, password, host)
	return hosts[host].users.create_user(username, password);
end

local function delete_user(username, host)
	local ok, err = hosts[host].users.delete_user(username);
	if not ok then return nil, err; end
	prosody.events.fire_event("user-deleted", { username = username, host = host });
	return storagemanager.purge(username, host);
end

local function users(host)
	return hosts[host].users.users();
end

local function get_sasl_handler(host, session)
	return hosts[host].users.get_sasl_handler(session);
end

local function get_provider(host)
	return hosts[host].users;
end

-- Returns a map of { [role_name] = role, ... } that a user is allowed to assume
local function get_user_roles(user, host)
	if host and not hosts[host] then return false; end
	if type(user) ~= "string" then return false; end

	host = host or "*";

	local authz_provider = (host ~= "*" and hosts[host].authz) or global_authz_provider;
	return authz_provider.get_user_roles(user);
end

local function get_user_default_role(user, host)
	if host and not hosts[host] then return false; end
	if type(user) ~= "string" then return false; end

	host = host or "*";

	local authz_provider = (host ~= "*" and hosts[host].authz) or global_authz_provider;
	return authz_provider.get_user_default_role(user);
end

-- Accepts a set of role names which the user is allowed to assume
local function set_user_roles(user, host, roles)
	if host and not hosts[host] then return false; end
	if type(user) ~= "string" then return false; end

	host = host or "*";

	local authz_provider = (host ~= "*" and hosts[host].authz) or global_authz_provider;
	local ok, err = authz_provider.set_user_roles(user, roles);
	if ok then
		prosody.events.fire_event("user-roles-changed", {
			username = user, host = host
		});
	end
	return ok, err;
end

local function get_jid_role(jid, host)
	host = host or "*";
	local authz_provider = (host ~= "*" and hosts[host].authz) or global_authz_provider;
	local jid_node, jid_host = jid_split(jid);
	if host == jid_host and jid_node then
		return authz_provider.get_user_default_role(jid_node);
	end
	return authz_provider.get_jid_role(jid);
end

local function set_jid_role(jid, host, role_name)
	host = host or "*";
	local authz_provider = (host ~= "*" and hosts[host].authz) or global_authz_provider;
	local _, jid_host = jid_split(jid);
	if host == jid_host then
		return nil, "unexpected-local-jid";
	end
	return authz_provider.set_jid_role(jid, role_name)
end

local function get_users_with_role(role, host)
	if not hosts[host] then return false; end
	if type(role) ~= "string" then return false; end

	return hosts[host].authz.get_users_with_role(role);
end

local function get_jids_with_role(role, host)
	if host and not hosts[host] then return false; end
	if type(role) ~= "string" then return false; end

	host = host or "*";

	local authz_provider = (host ~= "*" and hosts[host].authz) or global_authz_provider;
	return authz_provider.get_jids_with_role(role);
end

local function get_role_by_name(role_name, host)
	if host and not hosts[host] then return false; end
	if type(role_name) ~= "string" then return false; end

	host = host or "*";

	local authz_provider = (host ~= "*" and hosts[host].authz) or global_authz_provider;
	return authz_provider.get_role_by_name(role_name);
end

return {
	new_null_provider = new_null_provider;
	initialize_host = initialize_host;
	test_password = test_password;
	get_password = get_password;
	set_password = set_password;
	get_account_info = get_account_info;
	user_exists = user_exists;
	create_user = create_user;
	delete_user = delete_user;
	users = users;
	get_sasl_handler = get_sasl_handler;
	get_provider = get_provider;
	get_user_default_role = get_user_default_role;
	get_user_roles = get_user_roles;
	set_user_roles = set_user_roles;
	get_users_with_role = get_users_with_role;
	get_jid_role = get_jid_role;
	set_jid_role = set_jid_role;
	get_jids_with_role = get_jids_with_role;
	get_role_by_name = get_role_by_name;
};
