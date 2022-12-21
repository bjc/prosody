local adns = require "net.adns";
local inet_pton = require "util.net".pton;
local inet_ntop = require "util.net".ntop;
local idna_to_ascii = require "util.encodings".idna.to_ascii;
local promise = require "util.promise";
local t_move = require "util.table".move;

local methods = {};
local resolver_mt = { __index = methods };

-- FIXME RFC 6724

local function do_dns_lookup(self, dns_resolver, record_type, name, allow_insecure)
	return promise.new(function (resolve, reject)
		local ipv = (record_type == "A" and "4") or (record_type == "AAAA" and "6") or nil;
		if ipv and self.extra["use_ipv"..ipv] == false then
			return reject(("IPv%s disabled - %s lookup skipped"):format(ipv, record_type));
		elseif record_type == "TLSA" and self.extra.use_dane ~= true then
			return reject("DANE disabled - TLSA lookup skipped");
		end
		dns_resolver:lookup(function (answer, err)
			if not answer then
				return reject(err);
			elseif answer.bogus then
				return reject(("Validation error in %s lookup"):format(record_type));
			elseif not (answer.secure or allow_insecure) then
				return reject(("Insecure response in %s lookup"):format(record_type));
			elseif answer.status and #answer == 0 then
				return reject(("%s in %s lookup"):format(answer.status, record_type));
			end

			local targets = { secure = answer.secure };
			for _, record in ipairs(answer) do
				if ipv then
					table.insert(targets, { self.conn_type..ipv, record[record_type:lower()], self.port, self.extra });
				else
					table.insert(targets, record[record_type:lower()]);
				end
			end
			return resolve(targets);
		end, name, record_type, "IN");
	end);
end

local function merge_targets(ipv4_targets, ipv6_targets)
	local result = { secure = ipv4_targets.secure and ipv6_targets.secure };
	local common_length = math.min(#ipv4_targets, #ipv6_targets);
	for i = 1, common_length do
		table.insert(result, ipv6_targets[i]);
		table.insert(result, ipv4_targets[i]);
	end
	if common_length < #ipv4_targets then
		t_move(ipv4_targets, common_length+1, #ipv4_targets, common_length+1, result);
	elseif common_length < #ipv6_targets then
		t_move(ipv6_targets, common_length+1, #ipv6_targets, common_length+1, result);
	end
	return result;
end

-- Find the next target to connect to, and
-- pass it to cb()
function methods:next(cb)
	if self.targets then
		if #self.targets == 0 then
			cb(nil);
			return;
		end
		local next_target = table.remove(self.targets, 1);
		cb(next_target[1], next_target[2], next_target[3], next_target[4], not not self.targets[1]);
		return;
	end

	if not self.hostname then
		self.last_error = "hostname failed IDNA";
		cb(nil);
		return;
	end

	-- Resolve DNS to target list
	local dns_resolver = adns.resolver();

	local dns_lookups = {
		ipv4 = do_dns_lookup(self, dns_resolver, "A", self.hostname, true);
		ipv6 = do_dns_lookup(self, dns_resolver, "AAAA", self.hostname, true);
		tlsa = do_dns_lookup(self, dns_resolver, "TLSA", ("_%d._%s.%s"):format(self.port, self.conn_type, self.hostname));
	};

	promise.all_settled(dns_lookups):next(function (dns_results)
		-- Combine targets, assign to self.targets, self:next(cb)
		local have_ipv4 = dns_results.ipv4.status == "fulfilled";
		local have_ipv6 = dns_results.ipv6.status == "fulfilled";

		if have_ipv4 and have_ipv6 then
			self.targets = merge_targets(dns_results.ipv4.value, dns_results.ipv6.value);
		elseif have_ipv4 then
			self.targets = dns_results.ipv4.value;
		elseif have_ipv6 then
			self.targets = dns_results.ipv6.value;
		else
			self.targets = {};
		end

		if self.extra and self.extra.use_dane then
			if self.targets.secure and dns_results.tlsa.status == "fulfilled" then
				self.extra.tlsa = dns_results.tlsa.value;
				self.extra.dane_hostname = self.hostname;
			else
				self.extra.tlsa = nil;
				self.extra.dane_hostname = nil;
			end
		elseif self.extra and self.extra.srv_secure then
			self.extra.secure_hostname = self.hostname;
		end

		self:next(cb);
	end):catch(function (err)
		self.last_error = err;
		self.targets = {};
	end);
end

local function new(hostname, port, conn_type, extra)
	local ascii_host = idna_to_ascii(hostname);
	local targets = nil;
	conn_type = conn_type or "tcp";

	local is_ip = inet_pton(hostname);
	if not is_ip and hostname:sub(1,1) == '[' then
		is_ip = inet_pton(hostname:sub(2,-2));
	end
	if is_ip then
		hostname = inet_ntop(is_ip);
		if #is_ip == 16 then
			targets = { { conn_type.."6", hostname, port, extra } };
		elseif #is_ip == 4 then
			targets = { { conn_type.."4", hostname, port, extra } };
		end
	end

	return setmetatable({
		hostname = ascii_host;
		port = port;
		conn_type = conn_type;
		extra = extra or {};
		targets = targets;
	}, resolver_mt);
end

return {
	new = new;
};
