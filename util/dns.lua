-- libunbound based net.adns replacement for Prosody IM
-- Copyright (C) 2012-2015 Kim Alvefur
-- Copyright (C) 2012 Waqas Hussain
--
-- This file is MIT licensed.

local setmetatable = setmetatable;
local table = table;
local t_concat = table.concat;
local t_insert = table.insert;
local s_byte = string.byte;
local s_format = string.format;
local s_gsub = string.gsub;
local s_sub = string.sub;
local s_match = string.match;
local s_gmatch = string.gmatch;

local have_net, net_util = pcall(require, "util.net");

local iana_data = require "util.dnsregistry";
if have_net and not net_util.ntop then -- Added in Prosody 0.11
	have_net = false;
end

local tohex = require "util.hex".to;

-- Simplified versions of Waqas DNS parsers
-- Only the per RR parsers are needed and only feed a single RR

local parsers = {};

-- No support for pointers, but libunbound appears to take care of that.
local function readDnsName(packet, pos)
	if s_byte(packet, pos) == 0 then return ".", pos+1; end
	local pack_len, r, len = #packet, {};
	pos = pos or 1;
	repeat
		len = s_byte(packet, pos) or 0;
		t_insert(r, s_sub(packet, pos + 1, pos + len));
		pos = pos + len + 1;
	until len == 0 or pos >= pack_len;
	return t_concat(r, "."), pos;
end

-- These are just simple names.
parsers.CNAME = readDnsName;
parsers.NS = readDnsName
parsers.PTR = readDnsName;

local soa_mt = {
	__tostring = function(rr)
		return s_format("%s %s %d %d %d %d %d", rr.mname, rr.rname, rr.serial, rr.refresh, rr.retry, rr.expire, rr.minimum);
	end;
};
function parsers.SOA(packet)
	local mname, rname, offset;

	mname, offset = readDnsName(packet, 1);
	rname, offset = readDnsName(packet, offset);

	-- Extract all the bytes of these fields in one call
	local
		s1, s2, s3, s4, -- serial
		r1, r2, r3, r4, -- refresh
		t1, t2, t3, t4, -- retry
		e1, e2, e3, e4, -- expire
		m1, m2, m3, m4  -- minimum
			= s_byte(packet, offset, offset + 19);

	return setmetatable({
		mname = mname;
		rname = rname;
		serial  = s1*0x1000000 + s2*0x10000 + s3*0x100 + s4;
		refresh = r1*0x1000000 + r2*0x10000 + r3*0x100 + r4;
		retry   = t1*0x1000000 + t2*0x10000 + t3*0x100 + t4;
		expire  = e1*0x1000000 + e2*0x10000 + e3*0x100 + e4;
		minimum = m1*0x1000000 + m2*0x10000 + m3*0x100 + m4;
	}, soa_mt);
end

function parsers.A(packet)
	return s_format("%d.%d.%d.%d", s_byte(packet, 1, 4));
end

local aaaa = { nil, nil, nil, nil, nil, nil, nil, nil, };
function parsers.AAAA(packet)
	local hi, lo, ip, len, token;
	for i = 1, 8 do
		hi, lo = s_byte(packet, i * 2 - 1, i * 2);
		aaaa[i] = s_format("%x", hi * 256 + lo); -- skips leading zeros
	end
	ip = t_concat(aaaa, ":", 1, 8);
	len = (s_match(ip, "^0:[0:]+()") or 1) - 1;
	for s in s_gmatch(ip, ":0:[0:]+") do
		if len < #s then len, token = #s, s; end -- find longest sequence of zeros
	end
	return (s_gsub(ip, token or "^0:[0:]+", "::", 1));
end

if have_net then
	parsers.A = net_util.ntop;
	parsers.AAAA = net_util.ntop;
end

local mx_mt = {
	__tostring = function(rr)
		return s_format("%d %s", rr.pref, rr.mx)
	end
};
function parsers.MX(packet)
	local name = readDnsName(packet, 3);
	local b1,b2 = s_byte(packet, 1, 2);
	return setmetatable({
		pref = b1*256+b2;
		mx = name;
	}, mx_mt);
end

local srv_mt = {
	__tostring = function(rr)
		return s_format("%d %d %d %s", rr.priority, rr.weight, rr.port, rr.target);
	end
};
function parsers.SRV(packet)
	local name = readDnsName(packet, 7);
	local b1, b2, b3, b4, b5, b6 = s_byte(packet, 1, 6);
	return setmetatable({
		priority = b1*256+b2;
		weight   = b3*256+b4;
		port     = b5*256+b6;
		target   = name;
	}, srv_mt);
end

local txt_mt = { __tostring = t_concat };
function parsers.TXT(packet)
	local pack_len = #packet;
	local r, pos, len = {}, 1;
	repeat
		len = s_byte(packet, pos) or 0;
		t_insert(r, s_sub(packet, pos + 1, pos + len));
		pos = pos + len + 1;
	until pos >= pack_len;
	return setmetatable(r, txt_mt);
end

parsers.SPF = parsers.TXT;

-- Acronyms from RFC 7218
local tlsa_usages = {
	[0] = "PKIX-CA";
	[1] = "PKIX-EE";
	[2] = "DANE-TA";
	[3] = "DANE-EE";
	[255] = "PrivCert";
};
local tlsa_selectors = {
	[0] = "Cert",
	[1] = "SPKI",
	[255] = "PrivSel",
};
local tlsa_match_types = {
	[0] = "Full",
	[1] = "SHA2-256",
	[2] = "SHA2-512",
	[255] = "PrivMatch",
};
local tlsa_mt = {
	__tostring = function(rr)
		return s_format("%s %s %s %s",
			tlsa_usages[rr.use] or rr.use,
			tlsa_selectors[rr.select] or rr.select,
			tlsa_match_types[rr.match] or rr.match,
			tohex(rr.data));
	end;
	__index = {
		getUsage = function(rr) return tlsa_usages[rr.use] end;
		getSelector = function(rr) return tlsa_selectors[rr.select] end;
		getMatchType = function(rr) return tlsa_match_types[rr.match] end;
	}
};
function parsers.TLSA(packet)
	local use, select, match = s_byte(packet, 1,3);
	return setmetatable({
		use = use;
		select = select;
		match = match;
		data = s_sub(packet, 4);
	}, tlsa_mt);
end

local svcb_params = {"alpn"; "no-default-alpn"; "port"; "ipv4hint"; "ech"; "ipv6hint"};
setmetatable(svcb_params, {__index = function(_, n) return "key" .. tostring(n); end});

local svcb_mt = {
	__tostring = function (rr)
		local kv = {};
		for i = 1, #rr.fields do
			t_insert(kv, s_format("%s=%q", svcb_params[rr.fields[i].key], tostring(rr.fields[i].value)));
			-- FIXME the =value part may be omitted when the value is "empty"
		end
		return s_format("%d %s %s", rr.prio, rr.name, t_concat(kv, " "));
	end;
};
local svbc_ip_mt = {__tostring = function(ip) return t_concat(ip, ", "); end}

function parsers.SVCB(packet)
	local prio_h, prio_l = packet:byte(1,2);
	local prio = prio_h*256+prio_l;
	local name, pos = readDnsName(packet, 3);
	local fields = {};
	while #packet > pos do
		local key_h, key_l = packet:byte(pos+0,pos+1);
		local len_h, len_l = packet:byte(pos+2,pos+3);
		local key = key_h*256+key_l;
		local len = len_h*256+len_l;
		local value = packet:sub(pos+4,pos+4-1+len)
		if key == 1 then
			value = setmetatable(parsers.TXT(value), svbc_ip_mt);
		elseif key == 3 then
			local port_h, port_l = value:byte(1,2);
			local port = port_h*256+port_l;
			value = port;
		elseif key == 4 then
			local ip = {};
			for i = 1, #value, 4 do
				t_insert(ip, parsers.A(value:sub(i, i+3)));
			end
			value = setmetatable(ip, svbc_ip_mt);
		elseif key == 6 then
			local ip = {};
			for i = 1, #value, 16 do
				t_insert(ip, parsers.AAAA(value:sub(i, i+15)));
			end
			value = setmetatable(ip, svbc_ip_mt);
		end
		t_insert(fields, { key = key, value = value, len = len });
		pos = pos+len+4;
	end
	return setmetatable({
			prio = prio, name = name, fields = fields,
		}, svcb_mt);
end

parsers.HTTPS = parsers.SVCB;

local params = {
	TLSA = {
		use = tlsa_usages;
		select = tlsa_selectors;
		match = tlsa_match_types;
	};
};

local fallback_mt = {
	__tostring = function(rr)
		return s_format([[\# %d %s]], #rr.raw, tohex(rr.raw));
	end;
};
local function fallback_parser(packet)
	return setmetatable({ raw = packet },fallback_mt);
end
setmetatable(parsers, { __index = function() return fallback_parser end });

return {
	parsers = parsers;
	classes = iana_data.classes;
	types = iana_data.types;
	errors = iana_data.errors;
	params = params;
};
