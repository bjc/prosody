local array = require "util.array";
local it = require "util.iterators";
local set = require "util.set";
local jid_split = require "util.jid".split;
local normalize = require "util.jid".prep;
local config_admin_jids = module:get_option_inherited_set("admins", {}) / normalize;
local host = module.host;
local role_store = module:open_store("roles");
local role_map_store = module:open_store("roles", "map");

local admin_role = { ["prosody:admin"] = true };

function get_user_roles(user)
	if config_admin_jids:contains(user.."@"..host) then
		return admin_role;
	end
	return role_store:get(user);
end

function set_user_roles(user, roles)
	role_store:set(user, roles)
	return true;
end

function get_users_with_role(role)
	local storage_role_users = it.to_array(it.keys(role_map_store:get_all(role) or {}));
	if role == "prosody:admin" then
		local config_admin_users = config_admin_jids / function (admin_jid)
			local j_node, j_host = jid_split(admin_jid);
			if j_host == host then
				return j_node;
			end
		end;
		return it.to_array(config_admin_users + set.new(storage_role_users));
	end
	return storage_role_users;
end

function get_jid_roles(jid)
	if config_admin_jids:contains(jid) then
		return admin_role;
	end
	return nil;
end

function set_jid_roles(jid) -- luacheck: ignore 212
	return false;
end

function get_jids_with_role(role)
	-- Fetch role users from storage
	local storage_role_jids = array.map(get_users_with_role(role), function (username)
		return username.."@"..host;
	end);
	if role == "prosody:admin" then
		return it.to_array(config_admin_jids + set.new(storage_role_jids));
	end
	return storage_role_jids;
end
