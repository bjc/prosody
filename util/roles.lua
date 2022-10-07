local array = require "util.array";
local it = require "util.iterators";
local new_short_id = require "util.id".short;

local role_methods = {};
local role_mt = {
	__index = role_methods;
	__name = "role";
	__add = nil;
};

local function is_role(o)
	local mt = getmetatable(o);
	return mt == role_mt;
end

local function _new_may(permissions, inherited_mays)
	local n_inherited = inherited_mays and #inherited_mays;
	return function (role, action, context)
		-- Note: 'role' may be a descendent role, not only the one we're attached to
		local policy = permissions[action];
		if policy ~= nil then
			return policy;
		end
		if n_inherited then
			for i = 1, n_inherited do
				policy = inherited_mays[i](role, action, context);
				if policy ~= nil then
					return policy;
				end
			end
		end
		return nil;
	end
end

local permissions_key = {};

-- {
-- Required:
--   name = "My fancy role";
--
-- Optional:
--   inherits = { role_obj... }
--   default = true
--   priority = 100
--   permissions = {
--     ["foo"] = true; -- allow
--     ["bar"] = false; -- deny
--   }
-- }
local function new(base_config, overrides)
	local config = setmetatable(overrides or {}, { __index = base_config });
	local permissions = {};
	local inherited_mays;
	if config.inherits then
		inherited_mays = array.pluck(config.inherits, "may");
	end
	local new_role = {
		id = new_short_id();
		name = config.name;
		description = config.description;
		default = config.default;
		priority = config.priority;
		may = _new_may(permissions, inherited_mays);
		inherits = config.inherits;
		[permissions_key] = permissions;
	};
	local desired_permissions = config.permissions or config[permissions_key];
	for k, v in pairs(desired_permissions or {}) do
		permissions[k] = v;
	end
	return setmetatable(new_role, role_mt);
end

function role_methods:clone(overrides)
	return new(self, overrides);
end

function role_methods:set_permission(permission_name, policy, overwrite)
	local permissions = self[permissions_key];
	if overwrite ~= true and permissions[permission_name] ~= nil and permissions[permission_name] ~= policy then
		return false, "policy-already-exists";
	end
	permissions[permission_name] = policy;
	return true;
end

function role_mt.__tostring(self)
	return ("role<[%s] %s>"):format(self.id or "nil", self.name or "[no name]");
end

function role_mt.__pairs(self)
	return it.filter(permissions_key, next, self);
end

return {
	is_role = is_role;
	new = new;
};
