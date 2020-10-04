
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

return {
	classes = classes;
	types = types;
	errors = errors;
};
