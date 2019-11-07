local adns = require "net.adns";
local basic = require "net.resolvers.basic";
local idna_to_ascii = require "util.encodings".idna.to_ascii;

local methods = {};
local resolver_mt = { __index = methods };

-- Find the next target to connect to, and
-- pass it to cb()
function methods:next(cb)
	if self.targets then
		if #self.targets == 0 then
			cb(nil);
			return;
		end
		local next_target = table.remove(self.targets, 1);
		self.resolver = basic.new(unpack(next_target, 1, 4));
		self.resolver:next(function (...)
			if ... == nil then
				self:next(cb);
			else
				cb(...);
			end
		end);
		return;
	end

	if not self.hostname then
		-- FIXME report IDNA error
		cb(nil);
		return;
	end

	local targets = {};
	local function ready()
		self.targets = targets;
		self:next(cb);
	end

	-- Resolve DNS to target list
	local dns_resolver = adns.resolver();
	dns_resolver:lookup(function (answer)
		if answer then
			if #answer == 0 then
				if self.extra and self.extra.default_port then
					table.insert(targets, { self.hostname, self.extra.default_port, self.conn_type, self.extra });
				end
				ready();
				return;
			end

			if #answer == 1 and answer[1].srv.target == "." then -- No service here
				ready();
				return;
			end

			table.sort(answer, function (a, b) return a.srv.priority < b.srv.priority end);
			for _, record in ipairs(answer) do
				table.insert(targets, { record.srv.target, record.srv.port, self.conn_type, self.extra });
			end
		end
		ready();
	end, "_" .. self.service .. "._" .. self.conn_type .. "." .. self.hostname, "SRV", "IN");
end

local function new(hostname, service, conn_type, extra)
	return setmetatable({
		hostname = idna_to_ascii(hostname);
		service = service;
		conn_type = conn_type or "tcp";
		extra = extra;
	}, resolver_mt);
end

return {
	new = new;
};
