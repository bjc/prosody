local normalize = require "util.jid".prep;
local admin_jids = module:get_option_inherited_set("admins", {}) / normalize;
local host = module.host;
local role_store = module:open_store("roles");

local admin_role = { ["prosody:admin"] = true };

function get_user_roles(user)
	if admin_jids:contains(user.."@"..host) then
		return admin_role;
	end
	return role_store:get(user);
end

function get_jid_roles(jid)
	if admin_jids:contains(jid) then
		return admin_role;
	end
	return nil;
end


