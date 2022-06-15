local array = require "util.array";
local it = require "util.iterators";
local set = require "util.set";
local jid_split, jid_bare = require "util.jid".split, require "util.jid".bare;
local normalize = require "util.jid".prep;
local config_global_admin_jids = module:context("*"):get_option_set("admins", {}) / normalize;
local config_admin_jids = module:get_option_inherited_set("admins", {}) / normalize;
local host = module.host;
local role_store = module:open_store("roles");
local role_map_store = module:open_store("roles", "map");

local role_methods = {};
local role_mt = { __index = role_methods };

local role_registry = {
	["prosody:operator"] = {
		default = true;
		priority = 75;
		includes = { "prosody:admin" };
	};
	["prosody:admin"] = {
		default = true;
		priority = 50;
		includes = { "prosody:user" };
	};
	["prosody:user"] = {
		default = true;
		priority = 25;
		includes = { "prosody:restricted" };
	};
	["prosody:restricted"] = {
		default = true;
		priority = 15;
	};
};

-- Some processing on the role registry
for role_name, role_info in pairs(role_registry) do
	role_info.name = role_name;
	role_info.includes = set.new(role_info.includes) / function (included_role_name)
		return role_registry[included_role_name];
	end;
	if not role_info.permissions then
		role_info.permissions = {};
	end
	setmetatable(role_info, role_mt);
end

function role_methods:may(action, context)
	local policy = self.permissions[action];
	if policy ~= nil then
		return policy;
	end
	for inherited_role in self.includes do
		module:log("debug", "Checking included role '%s' for %s", inherited_role.name, action);
		policy = inherited_role:may(action, context);
		if policy ~= nil then
			return policy;
		end
	end
	return false;
end

-- Public API

local config_operator_role_set = {
	["prosody:operator"] = role_registry["prosody:operator"];
};
local config_admin_role_set = {
	["prosody:admin"] = role_registry["prosody:admin"];
};

function get_user_roles(user)
	local bare_jid = user.."@"..host;
	if config_global_admin_jids:contains(bare_jid) then
		return config_operator_role_set;
	elseif config_admin_jids:contains(bare_jid) then
		return config_admin_role_set;
	end
	local role_names = role_store:get(user);
	if not role_names then return {}; end
	local roles = {};
	for role_name in pairs(role_names) do
		roles[role_name] = role_registry[role_name];
	end
	return roles;
end

function set_user_roles(user, roles)
	role_store:set(user, roles)
	return true;
end

function get_user_default_role(user)
	local roles = get_user_roles(user);
	if not roles then return nil; end
	local default_role;
	for role_name, role_info in pairs(roles) do --luacheck: ignore 213/role_name
		if role_info.default and (not default_role or role_info.priority > default_role.priority) then
			default_role = role_info;
		end
	end
	if not default_role then return nil; end
	return default_role;
end

function get_users_with_role(role_name)
	local storage_role_users = it.to_array(it.keys(role_map_store:get_all(role_name) or {}));
	local config_set;
	if role_name == "prosody:admin" then
		config_set = config_admin_jids;
	elseif role_name == "prosody:operator" then
		config_set = config_global_admin_jids;
	end
	if config_set then
		local config_admin_users = config_set / function (admin_jid)
			local j_node, j_host = jid_split(admin_jid);
			if j_host == host then
				return j_node;
			end
		end;
		return it.to_array(config_admin_users + set.new(storage_role_users));
	end
	return storage_role_users;
end

function get_jid_role(jid)
	local bare_jid = jid_bare(jid);
	if config_global_admin_jids:contains(bare_jid) then
		return role_registry["prosody:operator"];
	elseif config_admin_jids:contains(bare_jid) then
		return role_registry["prosody:admin"];
	end
	return nil;
end

function set_jid_role(jid) -- luacheck: ignore 212
	return false;
end

function get_jids_with_role(role_name)
	-- Fetch role users from storage
	local storage_role_jids = array.map(get_users_with_role(role_name), function (username)
		return username.."@"..host;
	end);
	if role_name == "prosody:admin" then
		return it.to_array(config_admin_jids + set.new(storage_role_jids));
	elseif role_name == "prosody:operator" then
		return it.to_array(config_global_admin_jids + set.new(storage_role_jids));
	end
	return storage_role_jids;
end

function add_default_permission(role_name, action, policy)
	local role = role_registry[role_name];
	if not role then
		module:log("warn", "Attempt to add default permission for unknown role: %s", role_name);
		return nil, "no-such-role";
	end
	if role.permissions[action] == nil then
		if policy == nil then
			policy = true;
		end
		module:log("debug", "Adding permission, role '%s' may '%s': %s", role_name, action, policy and "allow" or "deny");
		role.permissions[action] = policy;
	end
	return true;
end

function get_role_info(role_name)
	return role_registry[role_name];
end
