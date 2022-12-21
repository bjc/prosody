local adns = require "net.adns";
local basic = require "net.resolvers.basic";
local inet_pton = require "util.net".pton;
local idna_to_ascii = require "util.encodings".idna.to_ascii;

local methods = {};
local resolver_mt = { __index = methods };

local function new_target_selector(rrset)
	local rr_count = rrset and #rrset;
	if not rr_count or rr_count == 0 then
		rrset = nil;
	else
		table.sort(rrset, function (a, b) return a.srv.priority < b.srv.priority end);
	end
	local rrset_pos = 1;
	local priority_bucket, bucket_total_weight, bucket_len, bucket_used;
	return function ()
		if not rrset then return; end

		if not priority_bucket or bucket_used >= bucket_len then
			if rrset_pos > rr_count then return; end -- Used up all records

			-- Going to start on a new priority now. Gather up all the next
			-- records with the same priority and add them to priority_bucket
			priority_bucket, bucket_total_weight, bucket_len, bucket_used = {}, 0, 0, 0;
			local current_priority;
			repeat
				local curr_record = rrset[rrset_pos].srv;
				if not current_priority then
					current_priority = curr_record.priority;
				elseif current_priority ~= curr_record.priority then
					break;
				end
				table.insert(priority_bucket, curr_record);
				bucket_total_weight = bucket_total_weight + curr_record.weight;
				bucket_len = bucket_len + 1;
				rrset_pos = rrset_pos + 1;
			until rrset_pos > rr_count;
		end

		bucket_used = bucket_used + 1;
		local n, running_total = math.random(0, bucket_total_weight), 0;
		local target_record;
		for i = 1, bucket_len do
			local candidate = priority_bucket[i];
			if candidate then
				running_total = running_total + candidate.weight;
				if running_total >= n then
					target_record = candidate;
					bucket_total_weight = bucket_total_weight - candidate.weight;
					priority_bucket[i] = nil;
					break;
				end
			end
		end
		return target_record;
	end;
end

-- Find the next target to connect to, and
-- pass it to cb()
function methods:next(cb)
	if self.resolver or self._get_next_target then
		if not self.resolver then -- Do we have a basic resolver currently?
			-- We don't, so fetch a new SRV target, create a new basic resolver for it
			local next_srv_target = self._get_next_target and self._get_next_target();
			if not next_srv_target then
				-- No more SRV targets left
				cb(nil);
				return;
			end
			-- Create a new basic resolver for this SRV target
			self.resolver = basic.new(next_srv_target.target, next_srv_target.port, self.conn_type, self.extra);
		end
		-- Look up the next (basic) target from the current target's resolver
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
	elseif self.in_progress then
		cb(nil);
		return;
	end

	if not self.hostname then
		self.last_error = "hostname failed IDNA";
		cb(nil);
		return;
	end

	self.in_progress = true;

	local function ready()
		self:next(cb);
	end

	-- Resolve DNS to target list
	local dns_resolver = adns.resolver();
	dns_resolver:lookup(function (answer, err)
		if not answer and not err then
			-- net.adns returns nil if there are zero records or nxdomain
			answer = {};
		end
		if answer then
			if answer.bogus then
				self.last_error = "Validation error in SRV lookup";
				ready();
				return;
			elseif not answer.secure then
				if self.extra then
					-- Insecure results, so no DANE
					self.extra.use_dane = false;
				end
			end
			if self.extra then
				self.extra.srv_secure = answer.secure;
			end

			if #answer == 0 then
				if self.extra and self.extra.default_port then
					self.resolver = basic.new(self.hostname, self.extra.default_port, self.conn_type, self.extra);
				else
					self.last_error = "zero SRV records found";
				end
				ready();
				return;
			end

			if #answer == 1 and answer[1].srv.target == "." then -- No service here
				self.last_error = "service explicitly unavailable";
				ready();
				return;
			end

			self._get_next_target = new_target_selector(answer);
		else
			self.last_error = err;
		end
		ready();
	end, "_" .. self.service .. "._" .. self.conn_type .. "." .. self.hostname, "SRV", "IN");
end

local function new(hostname, service, conn_type, extra)
	local is_ip = inet_pton(hostname);
	if not is_ip and hostname:sub(1,1) == '[' then
		is_ip = inet_pton(hostname:sub(2,-2));
	end
	if is_ip and extra and extra.default_port then
		return basic.new(hostname, extra.default_port, conn_type, extra);
	end

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
