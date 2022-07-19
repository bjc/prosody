local array = require "util.array";
local it = require "util.iterators";
local set = require "util.set";
local jid_split, jid_bare = require "util.jid".split, require "util.jid".bare;
local normalize = require "util.jid".prep;
local roles = require "util.roles";

local config_global_admin_jids = module:context("*"):get_option_set("admins", {}) / normalize;
local config_admin_jids = module:get_option_inherited_set("admins", {}) / normalize;
local host = module.host;
local role_store = module:open_store("roles");
local role_map_store = module:open_store("roles", "map");

local role_registry = {};

function register_role(role)
	if role_registry[role.name] ~= nil then
		return error("A role '"..role.name.."' is already registered");
	end
	if not roles.is_role(role) then
		-- Convert table syntax to real role object
		for i, inherited_role in ipairs(role.inherits or {}) do
			if type(inherited_role) == "string" then
				role.inherits[i] = assert(role_registry[inherited_role], "The named role '"..inherited_role.."' is not registered");
			end
		end
		if not role.permissions then role.permissions = {}; end
		for _, allow_permission in ipairs(role.allow or {}) do
			role.permissions[allow_permission] = true;
		end
		for _, deny_permission in ipairs(role.deny or {}) do
			role.permissions[deny_permission] = false;
		end
		role = roles.new(role);
	end
	role_registry[role.name] = role;
end

-- Default roles
register_role {
	name = "prosody:restricted";
	priority = 15;
};

register_role {
	name = "prosody:user";
	priority = 25;
	inherits = { "prosody:restricted" };
};

register_role {
	name = "prosody:admin";
	priority = 50;
	inherits = { "prosody:user" };
};

register_role {
	name = "prosody:operator";
	priority = 75;
	inherits = { "prosody:admin" };
};


-- Process custom roles from config

local custom_roles = module:get_option("custom_roles", {});
for n, role_config in ipairs(custom_roles) do
	local ok, err = pcall(register_role, role_config);
	if not ok then
		module:log("error", "Error registering custom role %s: %s", role_config.name or tostring(n), err);
	end
end

-- Process custom permissions from config

local config_add_perms = module:get_option("add_permissions", {});
local config_remove_perms = module:get_option("remove_permissions", {});

for role_name, added_permissions in pairs(config_add_perms) do
	if not role_registry[role_name] then
		module:log("error", "Cannot add permissions to unknown role '%s'", role_name);
	else
		for _, permission in ipairs(added_permissions) do
			role_registry[role_name]:set_permission(permission, true, true);
		end
	end
end

for role_name, removed_permissions in pairs(config_remove_perms) do
	if not role_registry[role_name] then
		module:log("error", "Cannot remove permissions from unknown role '%s'", role_name);
	else
		for _, permission in ipairs(removed_permissions) do
			role_registry[role_name]:set_permission(permission, false, true);
		end
	end
end

-- Public API

local config_operator_role_set = {
	["prosody:operator"] = role_registry["prosody:operator"];
};
local config_admin_role_set = {
	["prosody:admin"] = role_registry["prosody:admin"];
};
local default_role_set = {
	["prosody:user"] = role_registry["prosody:user"];
};

function get_user_roles(user)
	local bare_jid = user.."@"..host;
	if config_global_admin_jids:contains(bare_jid) then
		return config_operator_role_set;
	elseif config_admin_jids:contains(bare_jid) then
		return config_admin_role_set;
	end
	local role_names = role_store:get(user);
	if not role_names then return default_role_set; end
	local user_roles = {};
	for role_name in pairs(role_names) do
		user_roles[role_name] = role_registry[role_name];
	end
	return user_roles;
end

function set_user_roles(user, user_roles)
	role_store:set(user, user_roles)
	return true;
end

function get_user_default_role(user)
	local user_roles = get_user_roles(user);
	if not user_roles then return nil; end
	local default_role;
	for role_name, role_info in pairs(user_roles) do --luacheck: ignore 213/role_name
		if role_info.default ~= false and (not default_role or role_info.priority > default_role.priority) then
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

function set_jid_role(jid, role_name) -- luacheck: ignore 212
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
	if policy == nil then policy = true; end
	module:log("debug", "Adding policy %s for permission %s on role %s", policy, action, role_name);
	return role:set_permission(action, policy);
end

function get_role_by_name(role_name)
	return assert(role_registry[role_name], role_name);
end
