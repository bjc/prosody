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
local s_char = string.char;
local s_format = string.format;
local s_gsub = string.gsub;
local s_sub = string.sub;
local s_match = string.match;
local s_gmatch = string.gmatch;

local have_net, net_util = pcall(require, "util.net");

if have_net and not net_util.ntop then -- Added in Prosody 0.11
	have_net = false;
end

local chartohex = {};

for c = 0, 255 do
	chartohex[s_char(c)] = s_format("%02X", c);
end

local function tohex(s)
	return (s_gsub(s, ".", chartohex));
end

-- Converted from
-- http://www.iana.org/assignments/dns-parameters
-- 2020-06-25

local classes = {
	IN = 1; "IN";
	nil;
	CH = 3; "CH";
	HS = 4; "HS";
};

local types = {
"A";"NS";"MD";"MF";"CNAME";"SOA";"MB";"MG";"MR";"NULL";"WKS";"PTR";"HINFO";
"MINFO";"MX";"TXT";"RP";"AFSDB";"X25";"ISDN";"RT";"NSAP";"NSAP-PTR";"SIG";
"KEY";"PX";"GPOS";"AAAA";"LOC";"NXT";"EID";"NIMLOC";"SRV";"ATMA";"NAPTR";
"KX";"CERT";"A6";"DNAME";"SINK";"OPT";"APL";"DS";"SSHFP";"IPSECKEY";"RRSIG";
"NSEC";"DNSKEY";"DHCID";"NSEC3";"NSEC3PARAM";"TLSA";"SMIMEA";[55]="HIP";
[56]="NINFO";[57]="RKEY";[58]="TALINK";[59]="CDS";[60]="CDNSKEY";[61]="OPENPGPKEY";
[62]="CSYNC";[63]="ZONEMD";[99]="SPF";[100]="UINFO";[101]="UID";[102]="GID";
[103]="UNSPEC";[104]="NID";[105]="L32";[106]="L64";[107]="LP";[108]="EUI48";
[109]="EUI64";["CSYNC"]=62;["TXT"]=16;["NAPTR"]=35;["A6"]=38;["RP"]=17;
["TALINK"]=58;["NXT"]=30;["MR"]=9;["UINFO"]=100;["X25"]=19;["TKEY"]=249;
["CERT"]=37;["SMIMEA"]=53;[252]="AXFR";[253]="MAILB";["CDS"]=59;[32769]="DLV";
["RT"]=21;["WKS"]=11;[249]="TKEY";["LP"]=107;[250]="TSIG";["SSHFP"]=44;["DS"]=43;
["ISDN"]=20;["ATMA"]=34;["NS"]=2;[257]="CAA";["PX"]=26;["MX"]=15;["TSIG"]=250;
["EID"]=31;["TLSA"]=52;["GID"]=102;["KX"]=36;["SPF"]=99;["DOA"]=259;["GPOS"]=27;
["IPSECKEY"]=45;["NIMLOC"]=32;["RRSIG"]=46;["UID"]=101;["DNAME"]=39;["NSAP"]=22;
["DNSKEY"]=48;["SINK"]=40;["DHCID"]=49;[32768]="TA";["NSAP-PTR"]=23;["AAAA"]=28;
["PTR"]=12;["MINFO"]=14;["TA"]=32768;["EUI64"]=109;[260]="AMTRELAY";
["AMTRELAY"]=260;["CDNSKEY"]=60;[259]="DOA";["LOC"]=29;[258]="AVC";["AVC"]=258;
["CAA"]=257;["MB"]=7;["*"]=255;[256]="URI";["URI"]=256;["SRV"]=33;["EUI48"]=108;
[255]="*";[254]="MAILA";["MAILA"]=254;["MAILB"]=253;["CNAME"]=5;[251]="IXFR";
["APL"]=42;["OPENPGPKEY"]=61;["MD"]=3;["NINFO"]=56;["ZONEMD"]=63;["RKEY"]=57;
["L32"]=105;["NID"]=104;["HIP"]=55;["NSEC"]=47;["DLV"]=32769;["UNSPEC"]=103;
["NSEC3PARAM"]=51;["MF"]=4;["MG"]=8;["AFSDB"]=18;["A"]=1;["SIG"]=24;["NSEC3"]=50;
["HINFO"]=13;["IXFR"]=251;["NULL"]=10;["AXFR"]=252;["KEY"]=25;["OPT"]=41;
["SOA"]=6;["L64"]=106;
}

local errors = {
	NoError = "No Error"; [0] = "NoError";
	FormErr = "Format Error"; "FormErr";
	ServFail = "Server Failure"; "ServFail";
	NXDomain = "Non-Existent Domain"; "NXDomain";
	NotImp = "Not Implemented"; "NotImp";
	Refused = "Query Refused"; "Refused";
	YXDomain = "Name Exists when it should not"; "YXDomain";
	YXRRSet = "RR Set Exists when it should not"; "YXRRSet";
	NXRRSet = "RR Set that should exist does not"; "NXRRSet";
	NotAuth = "Server Not Authoritative for zone"; "NotAuth";
	NotZone = "Name not contained in zone"; "NotZone";
};

-- Simplified versions of Waqas DNS parsers
-- Only the per RR parsers are needed and only feed a single RR

local parsers = {};

-- No support for pointers, but libunbound appears to take care of that.
local function readDnsName(packet, pos)
	if s_byte(packet, pos) == 0 then return "."; end
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
	classes = classes;
	types = types;
	errors = errors;
	params = params;
};
