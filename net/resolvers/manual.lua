local methods = {};
local resolver_mt = { __index = methods };
local unpack = table.unpack or unpack; -- luacheck: ignore 113

-- Find the next target to connect to, and
-- pass it to cb()
function methods:next(cb)
	if #self.targets == 0 then
		cb(nil);
		return;
	end
	local next_target = table.remove(self.targets, 1);
	cb(unpack(next_target, 1, 4));
end

local function new(targets, conn_type, extra)
	return setmetatable({
		conn_type = conn_type;
		extra = extra;
		targets = targets or {};
	}, resolver_mt);
end

return {
	new = new;
};
