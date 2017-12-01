-- Prosody IM
-- Copyright (C) 2008-2011 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local net = require "util.net";
local hex = require "util.hex";

local ip_methods = {};

local ip_mt = {
	__index = function (ip, key)
		return ip_methods[key](ip);
	end,
	__tostring = function (ip) return ip.addr; end,
	__eq = function (ipA, ipB) return ipA.addr == ipB.addr; end
};

local hex2bits = {
	["0"] = "0000", ["1"] = "0001", ["2"] = "0010", ["3"] = "0011",
	["4"] = "0100", ["5"] = "0101", ["6"] = "0110", ["7"] = "0111",
	["8"] = "1000", ["9"] = "1001", ["A"] = "1010", ["B"] = "1011",
	["C"] = "1100", ["D"] = "1101", ["E"] = "1110", ["F"] = "1111",
};

local function new_ip(ipStr, proto)
	local zone;
	if (not proto or proto == "IPv6") and ipStr:find('%', 1, true) then
		ipStr, zone = ipStr:match("^(.-)%%(.*)");
	end

	local packed, err = net.pton(ipStr);
	if not packed then return packed, err end
	if proto == "IPv6" and #packed ~= 16 then
		return nil, "invalid-ipv6";
	elseif proto == "IPv4" and #packed ~= 4 then
		return nil, "invalid-ipv4";
	elseif not proto then
		if #packed == 16 then
			proto = "IPv6";
		elseif #packed == 4 then
			proto = "IPv4";
		else
			return nil, "unknown protocol";
		end
	elseif proto ~= "IPv6" and proto ~= "IPv4" then
		return nil, "invalid protocol";
	end

	return setmetatable({ addr = ipStr, packed = packed, proto = proto, zone = zone }, ip_mt);
end

function ip_methods:normal()
	return net.ntop(self.packed);
end

function ip_methods.bits(ip)
	return hex.to(ip.packed):upper():gsub(".", hex2bits);
end

function ip_methods.bits_full(ip)
	if ip.proto == "IPv4" then
		ip = ip.toV4mapped;
	end
	return ip.bits;
end

local function commonPrefixLength(ipA, ipB)
	ipA, ipB = ipA.bits_full, ipB.bits_full;
	for i = 1, 128 do
		if ipA:sub(i,i) ~= ipB:sub(i,i) then
			return i-1;
		end
	end
	return 128;
end

local function v4scope(ip)
	local fields = {};
	ip:gsub("([^.]*).?", function (c) fields[#fields + 1] = tonumber(c) end);
	-- Loopback:
	if fields[1] == 127 then
		return 0x2;
	-- Link-local unicast:
	elseif fields[1] == 169 and fields[2] == 254 then
		return 0x2;
	-- Global unicast:
	else
		return 0xE;
	end
end

local function v6scope(ip)
	-- Loopback:
	if ip:match("^[0:]*1$") then
		return 0x2;
	-- Link-local unicast:
	elseif ip:match("^[Ff][Ee][89ABab]") then
		return 0x2;
	-- Site-local unicast:
	elseif ip:match("^[Ff][Ee][CcDdEeFf]") then
		return 0x5;
	-- Multicast:
	elseif ip:match("^[Ff][Ff]") then
		return tonumber("0x"..ip:sub(4,4));
	-- Global unicast:
	else
		return 0xE;
	end
end

local function label(ip)
	if commonPrefixLength(ip, new_ip("::1", "IPv6")) == 128 then
		return 0;
	elseif commonPrefixLength(ip, new_ip("2002::", "IPv6")) >= 16 then
		return 2;
	elseif commonPrefixLength(ip, new_ip("2001::", "IPv6")) >= 32 then
		return 5;
	elseif commonPrefixLength(ip, new_ip("fc00::", "IPv6")) >= 7 then
		return 13;
	elseif commonPrefixLength(ip, new_ip("fec0::", "IPv6")) >= 10 then
		return 11;
	elseif commonPrefixLength(ip, new_ip("3ffe::", "IPv6")) >= 16 then
		return 12;
	elseif commonPrefixLength(ip, new_ip("::", "IPv6")) >= 96 then
		return 3;
	elseif commonPrefixLength(ip, new_ip("::ffff:0:0", "IPv6")) >= 96 then
		return 4;
	else
		return 1;
	end
end

local function precedence(ip)
	if commonPrefixLength(ip, new_ip("::1", "IPv6")) == 128 then
		return 50;
	elseif commonPrefixLength(ip, new_ip("2002::", "IPv6")) >= 16 then
		return 30;
	elseif commonPrefixLength(ip, new_ip("2001::", "IPv6")) >= 32 then
		return 5;
	elseif commonPrefixLength(ip, new_ip("fc00::", "IPv6")) >= 7 then
		return 3;
	elseif commonPrefixLength(ip, new_ip("fec0::", "IPv6")) >= 10 then
		return 1;
	elseif commonPrefixLength(ip, new_ip("3ffe::", "IPv6")) >= 16 then
		return 1;
	elseif commonPrefixLength(ip, new_ip("::", "IPv6")) >= 96 then
		return 1;
	elseif commonPrefixLength(ip, new_ip("::ffff:0:0", "IPv6")) >= 96 then
		return 35;
	else
		return 40;
	end
end

local function toV4mapped(ip)
	local fields = {};
	local ret = "::ffff:";
	ip:gsub("([^.]*).?", function (c) fields[#fields + 1] = tonumber(c) end);
	ret = ret .. ("%02x"):format(fields[1]);
	ret = ret .. ("%02x"):format(fields[2]);
	ret = ret .. ":"
	ret = ret .. ("%02x"):format(fields[3]);
	ret = ret .. ("%02x"):format(fields[4]);
	return new_ip(ret, "IPv6");
end

function ip_methods:toV4mapped()
	if self.proto ~= "IPv4" then return nil, "No IPv4 address" end
	local value = toV4mapped(self.addr);
	self.toV4mapped = value;
	return value;
end

function ip_methods:label()
	local value;
	if self.proto == "IPv4" then
		value = label(self.toV4mapped);
	else
		value = label(self);
	end
	self.label = value;
	return value;
end

function ip_methods:precedence()
	local value;
	if self.proto == "IPv4" then
		value = precedence(self.toV4mapped);
	else
		value = precedence(self);
	end
	self.precedence = value;
	return value;
end

function ip_methods:scope()
	local value;
	if self.proto == "IPv4" then
		value = v4scope(self.addr);
	else
		value = v6scope(self.addr);
	end
	self.scope = value;
	return value;
end

function ip_methods:private()
	local private = self.scope ~= 0xE;
	if not private and self.proto == "IPv4" then
		local ip = self.addr;
		local fields = {};
		ip:gsub("([^.]*).?", function (c) fields[#fields + 1] = tonumber(c) end);
		if fields[1] == 127 or fields[1] == 10 or (fields[1] == 192 and fields[2] == 168)
		or (fields[1] == 172 and (fields[2] >= 16 or fields[2] <= 32)) then
			private = true;
		end
	end
	self.private = private;
	return private;
end

local function parse_cidr(cidr)
	local bits;
	local ip_len = cidr:find("/", 1, true);
	if ip_len then
		bits = tonumber(cidr:sub(ip_len+1, -1));
		cidr = cidr:sub(1, ip_len-1);
	end
	return new_ip(cidr), bits;
end

local function match(ipA, ipB, bits)
	local common_bits = commonPrefixLength(ipA, ipB);
	if bits and ipB.proto == "IPv4" then
		common_bits = common_bits - 96; -- v6 mapped addresses always share these bits
	end
	return common_bits >= (bits or 128);
end

return {
	new_ip = new_ip,
	commonPrefixLength = commonPrefixLength,
	parse_cidr = parse_cidr,
	match = match,
};
