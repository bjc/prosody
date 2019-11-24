local adns = require "net.adns";
local inet_pton = require "util.net".pton;
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
		cb(unpack(next_target, 1, 4));
		return;
	end

	if not self.hostname then
		-- FIXME report IDNA error
		cb(nil);
		return;
	end

	local targets = {};
	local n = 2;
	local function ready()
		n = n - 1;
		if n > 0 then return; end
		self.targets = targets;
		self:next(cb);
	end

	-- Resolve DNS to target list
	local dns_resolver = adns.resolver();
	dns_resolver:lookup(function (answer)
		if answer then
			for _, record in ipairs(answer) do
				table.insert(targets, { self.conn_type.."4", record.a, self.port, self.extra });
			end
		end
		ready();
	end, self.hostname, "A", "IN");

	dns_resolver:lookup(function (answer)
		if answer then
			for _, record in ipairs(answer) do
				table.insert(targets, { self.conn_type.."6", record.aaaa, self.port, self.extra });
			end
		end
		ready();
	end, self.hostname, "AAAA", "IN");
end

local function new(hostname, port, conn_type, extra)
	local ascii_host = idna_to_ascii(hostname);
	local targets = nil;

	local is_ip = inet_pton(hostname);
	if not is_ip and hostname:sub(1,1) == '[' then
		is_ip = inet_pton(hostname:sub(2,-2));
	end
	if is_ip then
		if #is_ip == 16 then
			targets = { { conn_type.."6", hostname, port, extra } };
		elseif #is_ip == 4 then
			targets = { { conn_type.."4", hostname, port, extra } };
		end
	end

	return setmetatable({
		hostname = ascii_host;
		port = port;
		conn_type = conn_type or "tcp";
		extra = extra;
		targets = targets;
	}, resolver_mt);
end

return {
	new = new;
};
