local array = require "prosody.util.array";
local it = require "prosody.util.iterators";
local set = require "prosody.util.set";
local jid_split, jid_bare, jid_host = import("prosody.util.jid", "split", "bare", "host");
local normalize = require "prosody.util.jid".prep;
local roles = require "prosody.util.roles";

local config_global_admin_jids = module:context("*"):get_option_set("admins", {}) / normalize;
local config_admin_jids = module:get_option_inherited_set("admins", {}) / normalize;
local host = module.host;
local host_suffix = module:get_option_string("parent_host", (host:gsub("^[^%.]+%.", "")));

local hosts = prosody.hosts;
local is_anon_host = module:get_option_string("authentication") == "anonymous";
local default_user_role = module:get_option_string("default_user_role", is_anon_host and "prosody:guest" or "prosody:registered");

local is_component = hosts[host].type == "component";
local host_user_role, server_user_role, public_user_role;
if is_component then
	host_user_role = module:get_option_string("host_user_role", "prosody:registered");
	server_user_role = module:get_option_string("server_user_role", "prosody:guest");
	public_user_role = module:get_option_string("public_user_role", "prosody:guest");
end

local role_store = module:open_store("account_roles");
local role_map_store = module:open_store("account_roles", "map");

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

-- For untrusted guest/anonymous users
register_role {
	name = "prosody:guest";
	priority = 15;
};

-- For e.g. self-registered accounts
register_role {
	name = "prosody:registered";
	priority = 25;
	inherits = { "prosody:guest" };
};


-- For trusted/provisioned accounts
register_role {
	name = "prosody:member";
	priority = 35;
	inherits = { "prosody:registered" };
};

-- For administrators, e.g. of a host
register_role {
	name = "prosody:admin";
	priority = 50;
	inherits = { "prosody:member" };
};

-- For server operators (full access)
register_role {
	name = "prosody:operator";
	priority = 75;
	inherits = { "prosody:admin" };
};


-- Process custom roles from config

local custom_roles = module:get_option_array("custom_roles", {});
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

-- Get the primary role of a user
function get_user_role(user)
	local bare_jid = user.."@"..host;

	-- Check config first
	if config_global_admin_jids:contains(bare_jid) then
		return role_registry["prosody:operator"];
	elseif config_admin_jids:contains(bare_jid) then
		return role_registry["prosody:admin"];
	end

	-- Check storage
	local stored_roles, err = role_store:get(user);
	if not stored_roles then
		if err then
			-- Unable to fetch role, fail
			return nil, err;
		end
		-- No role set, use default role
		return role_registry[default_user_role];
	end
	if stored_roles._default == nil then
		-- No primary role explicitly set, return default
		return role_registry[default_user_role];
	end
	local primary_stored_role = role_registry[stored_roles._default];
	if not primary_stored_role then
		return nil, "unknown-role";
	end
	return primary_stored_role;
end

-- Set the primary role of a user
function set_user_role(user, role_name)
	local role = role_registry[role_name];
	if not role then
		return error("Cannot assign default user an unknown role: "..tostring(role_name));
	end
	local keys_update = {
		_default = role_name;
		-- Primary role cannot be secondary role
		[role_name] = role_map_store.remove;
	};
	if role_name == default_user_role then
		-- Don't store default
		keys_update._default = role_map_store.remove;
	end
	local ok, err = role_map_store:set_keys(user, keys_update);
	if not ok then
		return nil, err;
	end
	return role;
end

function add_user_secondary_role(user, role_name)
	if not role_registry[role_name] then
		return error("Cannot assign default user an unknown role: "..tostring(role_name));
	end
	role_map_store:set(user, role_name, true);
end

function remove_user_secondary_role(user, role_name)
	role_map_store:set(user, role_name, nil);
end

function get_user_secondary_roles(user)
	local stored_roles, err = role_store:get(user);
	if not stored_roles then
		if err then
			-- Unable to fetch role, fail
			return nil, err;
		end
		-- No role set
		return {};
	end
	stored_roles._default = nil;
	for role_name in pairs(stored_roles) do
		stored_roles[role_name] = role_registry[role_name];
	end
	return stored_roles;
end

function user_can_assume_role(user, role_name)
	local primary_role = get_user_role(user);
	if primary_role and primary_role.name == role_name then
		return true;
	end
	local secondary_roles = get_user_secondary_roles(user);
	if secondary_roles and secondary_roles[role_name] then
		return true;
	end
	return false;
end

-- This function is *expensive*
function get_users_with_role(role_name)
	local function role_filter(username, default_role) --luacheck: ignore 212/username
		return default_role == role_name;
	end
	local primary_role_users = set.new(it.to_array(it.filter(role_filter, pairs(role_map_store:get_all("_default") or {}))));
	local secondary_role_users = set.new(it.to_array(it.keys(role_map_store:get_all(role_name) or {})));

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
		return it.to_array(config_admin_users + primary_role_users + secondary_role_users);
	end
	return it.to_array(primary_role_users + secondary_role_users);
end

function get_jid_role(jid)
	local bare_jid = jid_bare(jid);
	if config_global_admin_jids:contains(bare_jid) then
		return role_registry["prosody:operator"];
	elseif config_admin_jids:contains(bare_jid) then
		return role_registry["prosody:admin"];
	elseif is_component then
		local user_host = jid_host(bare_jid);
		if host_user_role and user_host == host_suffix then
			return role_registry[host_user_role];
		elseif server_user_role and hosts[user_host] then
			return role_registry[server_user_role];
		elseif public_user_role then
			return role_registry[public_user_role];
		end
	end
	return nil;
end

function set_jid_role(jid, role_name) -- luacheck: ignore 212
	return false, "not-implemented";
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

function get_all_roles()
	return role_registry;
end

-- COMPAT: Migrate from 0.12 role storage
local function do_migration(migrate_host)
	local old_role_store = assert(module:context(migrate_host):open_store("roles"));
	local new_role_store = assert(module:context(migrate_host):open_store("account_roles"));

	local migrated, failed, skipped = 0, 0, 0;
	-- Iterate all users
	for username in assert(old_role_store:users()) do
		local old_roles = it.to_array(it.filter(function (k) return k:sub(1,1) ~= "_"; end, it.keys(old_role_store:get(username))));
		if #old_roles == 1 then
			local ok, err = new_role_store:set(username, {
				_default = old_roles[1];
			});
			if ok then
				migrated = migrated + 1;
			else
				failed = failed + 1;
				print("EE: Failed to store new role info for '"..username.."': "..err);
			end
		else
			print("WW: User '"..username.."' has multiple roles and cannot be automatically migrated");
			skipped = skipped + 1;
		end
	end
	return migrated, failed, skipped;
end

function module.command(arg)
	if arg[1] == "migrate" then
		table.remove(arg, 1);
		local migrate_host = arg[1];
		if not migrate_host or not prosody.hosts[migrate_host] then
			print("EE: Please supply a valid host to migrate to the new role storage");
			return 1;
		end

		-- Initialize storage layer
		require "prosody.core.storagemanager".initialize_host(migrate_host);

		print("II: Migrating roles...");
		local migrated, failed, skipped = do_migration(migrate_host);
		print(("II: %d migrated, %d failed, %d skipped"):format(migrated, failed, skipped));
		return (failed + skipped == 0) and 0 or 1;
	else
		print("EE: Unknown command: "..(arg[1] or "<none given>"));
		print("    Hint: try 'migrate'?");
	end
end
