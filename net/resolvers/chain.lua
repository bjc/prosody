
local methods = {};
local resolver_mt = { __index = methods };

-- Find the next target to connect to, and
-- pass it to cb()
function methods:next(cb)
	if self.resolvers then
		if not self.resolver then
			if #self.resolvers == 0 then
				cb(nil);
				return;
			end
			local next_resolver = table.remove(self.resolvers, 1);
			self.resolver = next_resolver;
		end
		self.resolver:next(function (...)
			if self.resolver then
				self.last_error = self.resolver.last_error;
			end
			if ... == nil then
				self.resolver = nil;
				self:next(cb);
			else
				cb(...);
			end
		end);
		return;
	end
end

local function new(resolvers)
	return setmetatable({ resolvers = resolvers }, resolver_mt);
end

return {
	new = new;
};
