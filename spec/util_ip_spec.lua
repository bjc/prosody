
local ip = require "util.ip";

local new_ip = ip.new_ip;
local match = ip.match;
local parse_cidr = ip.parse_cidr;
local commonPrefixLength = ip.commonPrefixLength;

describe("util.ip", function()
	describe("#match()", function()
		it("should work", function()
			local _ = new_ip;
			local ip = _"10.20.30.40";
			assert.are.equal(match(ip, _"10.0.0.0", 8), true);
			assert.are.equal(match(ip, _"10.0.0.0", 16), false);
			assert.are.equal(match(ip, _"10.0.0.0", 24), false);
			assert.are.equal(match(ip, _"10.0.0.0", 32), false);

			assert.are.equal(match(ip, _"10.20.0.0", 8), true);
			assert.are.equal(match(ip, _"10.20.0.0", 16), true);
			assert.are.equal(match(ip, _"10.20.0.0", 24), false);
			assert.are.equal(match(ip, _"10.20.0.0", 32), false);

			assert.are.equal(match(ip, _"0.0.0.0", 32), false);
			assert.are.equal(match(ip, _"0.0.0.0", 0), true);
			assert.are.equal(match(ip, _"0.0.0.0"), false);

			assert.are.equal(match(ip, _"10.0.0.0", 255), false, "excessive number of bits");
			assert.are.equal(match(ip, _"10.0.0.0", -8), true, "negative number of bits");
			assert.are.equal(match(ip, _"10.0.0.0", -32), true, "negative number of bits");
			assert.are.equal(match(ip, _"10.0.0.0", 0), true, "zero bits");
			assert.are.equal(match(ip, _"10.0.0.0"), false, "no specified number of bits (differing ip)");
			assert.are.equal(match(ip, _"10.20.30.40"), true, "no specified number of bits (same ip)");

			assert.are.equal(match(_"127.0.0.1", _"127.0.0.1"), true, "simple ip");

			assert.are.equal(match(_"8.8.8.8", _"8.8.0.0", 16), true);
			assert.are.equal(match(_"8.8.4.4", _"8.8.0.0", 16), true);
		end);
	end);

	describe("#parse_cidr()", function()
		it("should work", function()
			assert.are.equal(new_ip"0.0.0.0", new_ip"0.0.0.0")

			local function assert_cidr(cidr, ip, bits)
				local parsed_ip, parsed_bits = parse_cidr(cidr);
				assert.are.equal(new_ip(ip), parsed_ip, cidr.." parsed ip is "..ip);
				assert.are.equal(bits, parsed_bits, cidr.." parsed bits is "..tostring(bits));
			end
			assert_cidr("0.0.0.0", "0.0.0.0", nil);
			assert_cidr("127.0.0.1", "127.0.0.1", nil);
			assert_cidr("127.0.0.1/0", "127.0.0.1", 0);
			assert_cidr("127.0.0.1/8", "127.0.0.1", 8);
			assert_cidr("127.0.0.1/32", "127.0.0.1", 32);
			assert_cidr("127.0.0.1/256", "127.0.0.1", 256);
			assert_cidr("::/48", "::", 48);
		end);
	end);

	describe("#new_ip()", function()
		it("should work", function()
			local v4, v6 = "IPv4", "IPv6";
			local function assert_proto(s, proto)
				local ip = new_ip(s);
				if proto then
					assert.are.equal(ip and ip.proto, proto, "protocol is correct for "..("%q"):format(s));
				else
					assert.are.equal(ip, nil, "address is invalid");
				end
			end
			assert_proto("127.0.0.1", v4);
			assert_proto("::1", v6);
			assert_proto("", nil);
			assert_proto("abc", nil);
			assert_proto("   ", nil);
		end);
	end);

	describe("#commonPrefixLength()", function()
		it("should work", function()
			local function assert_cpl6(a, b, len, v4)
				local ipa, ipb = new_ip(a), new_ip(b);
				if v4 then len = len+96; end
				assert.are.equal(commonPrefixLength(ipa, ipb), len, "common prefix length of "..a.." and "..b.." is "..len);
				assert.are.equal(commonPrefixLength(ipb, ipa), len, "common prefix length of "..b.." and "..a.." is "..len);
			end
			local function assert_cpl4(a, b, len)
				return assert_cpl6(a, b, len, "IPv4");
			end
			assert_cpl4("0.0.0.0", "0.0.0.0", 32);
			assert_cpl4("255.255.255.255", "0.0.0.0", 0);
			assert_cpl4("255.255.255.255", "255.255.0.0", 16);
			assert_cpl4("255.255.255.255", "255.255.255.255", 32);
			assert_cpl4("255.255.255.255", "255.255.255.255", 32);

			assert_cpl6("::1", "::1", 128);
			assert_cpl6("abcd::1", "abcd::1", 128);
			assert_cpl6("abcd::abcd", "abcd::", 112);
			assert_cpl6("abcd::abcd", "abcd::abcd:abcd", 96);
		end);
	end);
end);
