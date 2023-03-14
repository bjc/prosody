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
		local method = ip_methods[key];
		if not method then return nil; end
		local ret = method(ip);
		ip[key] = ret;
		return ret;
	end,
	__tostring = function (ip) return ip.addr; end,
};
ip_mt.__eq = function (ipA, ipB)
	if getmetatable(ipA) ~= ip_mt or getmetatable(ipB) ~= ip_mt then
		-- Lua 5.3+ calls this if both operands are tables, even if metatables differ
		return false;
	end
	return ipA.packed == ipB.packed;
end

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
	return hex.encode(ip.packed):upper():gsub(".", hex2bits);
end

function ip_methods.bits_full(ip)
	if ip.proto == "IPv4" then
		ip = ip.toV4mapped;
	end
	return ip.bits;
end

local match;

local function commonPrefixLength(ipA, ipB)
	ipA, ipB = ipA.bits_full, ipB.bits_full;
	for i = 1, 128 do
		if ipA:sub(i,i) ~= ipB:sub(i,i) then
			return i-1;
		end
	end
	return 128;
end

-- Instantiate once
local loopback = new_ip("::1");
local loopback4 = new_ip("127.0.0.0");
local sixtofour = new_ip("2002::");
local teredo = new_ip("2001::");
local linklocal = new_ip("fe80::");
local linklocal4 = new_ip("169.254.0.0");
local uniquelocal = new_ip("fc00::");
local sitelocal = new_ip("fec0::");
local sixbone = new_ip("3ffe::");
local defaultunicast = new_ip("::");
local multicast = new_ip("ff00::");
local ipv6mapped = new_ip("::ffff:0:0");

local function v4scope(ip)
	if match(ip, loopback4, 8) then
		return 0x2;
	elseif match(ip, linklocal4, 16) then
		return 0x2;
	else -- Global unicast
		return 0xE;
	end
end

local function v6scope(ip)
	if ip == loopback then
		return 0x2;
	elseif match(ip, linklocal, 10) then
		return 0x2;
	elseif match(ip, sitelocal, 10) then
		return 0x5;
	elseif match(ip, multicast, 10) then
		return ip.packed:byte(2) % 0x10;
	else -- Global unicast
		return 0xE;
	end
end

local function label(ip)
	if ip == loopback then
		return 0;
	elseif match(ip, sixtofour, 16) then
		return 2;
	elseif match(ip, teredo, 32) then
		return 5;
	elseif match(ip, uniquelocal, 7) then
		return 13;
	elseif match(ip, sitelocal, 10) then
		return 11;
	elseif match(ip, sixbone, 16) then
		return 12;
	elseif match(ip, defaultunicast, 96) then
		return 3;
	elseif match(ip, ipv6mapped, 96) then
		return 4;
	else
		return 1;
	end
end

local function precedence(ip)
	if ip == loopback then
		return 50;
	elseif match(ip, sixtofour, 16) then
		return 30;
	elseif match(ip, teredo, 32) then
		return 5;
	elseif match(ip, uniquelocal, 7) then
		return 3;
	elseif match(ip, sitelocal, 10) then
		return 1;
	elseif match(ip, sixbone, 16) then
		return 1;
	elseif match(ip, defaultunicast, 96) then
		return 1;
	elseif match(ip, ipv6mapped, 96) then
		return 35;
	else
		return 40;
	end
end

function ip_methods:toV4mapped()
	if self.proto ~= "IPv4" then return nil, "No IPv4 address" end
	local value = new_ip("::ffff:" .. self.normal);
	return value;
end

function ip_methods:label()
	if self.proto == "IPv4" then
		return label(self.toV4mapped);
	else
		return label(self);
	end
end

function ip_methods:precedence()
	if self.proto == "IPv4" then
		return precedence(self.toV4mapped);
	else
		return precedence(self);
	end
end

function ip_methods:scope()
	if self.proto == "IPv4" then
		return v4scope(self);
	else
		return v6scope(self);
	end
end

local rfc1918_8 = new_ip("10.0.0.0");
local rfc1918_12 = new_ip("172.16.0.0");
local rfc1918_16 = new_ip("192.168.0.0");
local rfc6598 = new_ip("100.64.0.0");

function ip_methods:private()
	local private = self.scope ~= 0xE;
	if not private and self.proto == "IPv4" then
		return match(self, rfc1918_8, 8) or match(self, rfc1918_12, 12) or match(self, rfc1918_16, 16) or match(self, rfc6598, 10);
	end
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

function match(ipA, ipB, bits)
	if not bits or bits >= 128 or ipB.proto == "IPv4" and bits >= 32 then
		return ipA == ipB;
	elseif bits < 1 then
		return true;
	end
	if ipA.proto ~= ipB.proto then
		if ipA.proto == "IPv4" then
			ipA = ipA.toV4mapped;
		elseif ipB.proto == "IPv4" then
			ipB = ipB.toV4mapped;
			bits = bits + (128 - 32);
		end
	end
	return ipA.bits:sub(1, bits) == ipB.bits:sub(1, bits);
end

local function is_ip(obj)
	return getmetatable(obj) == ip_mt;
end

local function truncate(ip, n_bits)
	if n_bits % 8 ~= 0 then
		return error("ip.truncate() only supports multiples of 8 bits");
	end
	local n_octets = n_bits / 8;
	if not is_ip(ip) then
		ip = new_ip(ip);
	end
	return new_ip(net.ntop(ip.packed:sub(1, n_octets)..("\0"):rep(#ip.packed-n_octets)))
end

return {
	new_ip = new_ip,
	commonPrefixLength = commonPrefixLength,
	parse_cidr = parse_cidr,
	match = match,
	is_ip = is_ip;
	truncate = truncate;
};
