-- Prosody IM
-- Copyright (C) 2011-2013 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

function source(source)
	local new_ip = require"util.ip".new_ip;
	assert_equal(source(new_ip("2001:db8:1::1", "IPv6"),
			{new_ip("2001:db8:3::1", "IPv6"), new_ip("fe80::1", "IPv6")}).addr,
		"2001:db8:3::1",
		"prefer appropriate scope");
	assert_equal(source(new_ip("ff05::1", "IPv6"),
			{new_ip("2001:db8:3::1", "IPv6"), new_ip("fe80::1", "IPv6")}).addr,
		"2001:db8:3::1",
		"prefer appropriate scope");
	assert_equal(source(new_ip("2001:db8:1::1", "IPv6"),
			{new_ip("2001:db8:1::1", "IPv6"), new_ip("2001:db8:2::1", "IPv6")}).addr,
		"2001:db8:1::1",
		"prefer same address"); -- "2001:db8:1::1" should be marked "deprecated" here, we don't handle that right now
	assert_equal(source(new_ip("fe80::1", "IPv6"),
			{new_ip("fe80::2", "IPv6"), new_ip("2001:db8:1::1", "IPv6")}).addr,
		"fe80::2",
		"prefer appropriate scope"); -- "fe80::2" should be marked "deprecated" here, we don't handle that right now
	assert_equal(source(new_ip("2001:db8:1::1", "IPv6"),
			{new_ip("2001:db8:1::2", "IPv6"), new_ip("2001:db8:3::2", "IPv6")}).addr,
		"2001:db8:1::2",
		"longest matching prefix");
--[[ "2001:db8:1::2" should be a care-of address and "2001:db8:3::2" a home address, we can't handle this and would fail
	assert_equal(source(new_ip("2001:db8:1::1", "IPv6"),
			{new_ip("2001:db8:1::2", "IPv6"), new_ip("2001:db8:3::2", "IPv6")}).addr,
		"2001:db8:3::2",
		"prefer home address");
]]
	assert_equal(source(new_ip("2002:c633:6401::1", "IPv6"),
			{new_ip("2002:c633:6401::d5e3:7953:13eb:22e8", "IPv6"), new_ip("2001:db8:1::2", "IPv6")}).addr,
		"2002:c633:6401::d5e3:7953:13eb:22e8",
		"prefer matching label"); -- "2002:c633:6401::d5e3:7953:13eb:22e8" should be marked "temporary" here, we don't handle that right now
	assert_equal(source(new_ip("2001:db8:1::d5e3:0:0:1", "IPv6"),
			{new_ip("2001:db8:1::2", "IPv6"), new_ip("2001:db8:1::d5e3:7953:13eb:22e8", "IPv6")}).addr,
		"2001:db8:1::d5e3:7953:13eb:22e8",
		"prefer temporary address") -- "2001:db8:1::2" should be marked "public" and "2001:db8:1::d5e3:7953:13eb:22e8" should be marked "temporary" here, we don't handle that right now
end

function destination(dest)
	local order;
	local new_ip = require"util.ip".new_ip;
	order = dest({new_ip("2001:db8:1::1", "IPv6"), new_ip("198.51.100.121", "IPv4")},
		{new_ip("2001:db8:1::2", "IPv6"), new_ip("fe80::1", "IPv6"), new_ip("169.254.13.78", "IPv4")})
	assert_equal(order[1].addr, "2001:db8:1::1", "prefer matching scope");
	assert_equal(order[2].addr, "198.51.100.121", "prefer matching scope");

	order = dest({new_ip("2001:db8:1::1", "IPv6"), new_ip("198.51.100.121", "IPv4")},
		{new_ip("fe80::1", "IPv6"), new_ip("198.51.100.117", "IPv4")})
	assert_equal(order[1].addr, "198.51.100.121", "prefer matching scope");
	assert_equal(order[2].addr, "2001:db8:1::1", "prefer matching scope");

	order = dest({new_ip("2001:db8:1::1", "IPv6"), new_ip("10.1.2.3", "IPv4")},
		{new_ip("2001:db8:1::2", "IPv6"), new_ip("fe80::1", "IPv6"), new_ip("10.1.2.4", "IPv4")})
	assert_equal(order[1].addr, "2001:db8:1::1", "prefer higher precedence");
	assert_equal(order[2].addr, "10.1.2.3", "prefer higher precedence");

	order = dest({new_ip("2001:db8:1::1", "IPv6"), new_ip("fe80::1", "IPv6")},
		{new_ip("2001:db8:1::2", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "fe80::1", "prefer smaller scope");
	assert_equal(order[2].addr, "2001:db8:1::1", "prefer smaller scope");

--[[ "2001:db8:1::2" and "fe80::2" should be marked "care-of address", while "2001:db8:3::1" should be marked "home address", we can't currently handle this and would fail the test
	order = dest({new_ip("2001:db8:1::1", "IPv6"), new_ip("fe80::1", "IPv6")},
		{new_ip("2001:db8:1::2", "IPv6"), new_ip("2001:db8:3::1", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "2001:db8:1::1", "prefer home address");
	assert_equal(order[2].addr, "fe80::1", "prefer home address");
]]

--[[ "fe80::2" should be marked "deprecated", we can't currently handle this and would fail the test
	order = dest({new_ip("2001:db8:1::1", "IPv6"), new_ip("fe80::1", "IPv6")},
		{new_ip("2001:db8:1::2", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "2001:db8:1::1", "avoid deprecated addresses");
	assert_equal(order[2].addr, "fe80::1", "avoid deprecated addresses");
]]

	order = dest({new_ip("2001:db8:1::1", "IPv6"), new_ip("2001:db8:3ffe::1", "IPv6")},
		{new_ip("2001:db8:1::2", "IPv6"), new_ip("2001:db8:3f44::2", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "2001:db8:1::1", "longest matching prefix");
	assert_equal(order[2].addr, "2001:db8:3ffe::1", "longest matching prefix");

	order = dest({new_ip("2002:c633:6401::1", "IPv6"), new_ip("2001:db8:1::1", "IPv6")},
		{new_ip("2002:c633:6401::2", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "2002:c633:6401::1", "prefer matching label");
	assert_equal(order[2].addr, "2001:db8:1::1", "prefer matching label");

	order = dest({new_ip("2002:c633:6401::1", "IPv6"), new_ip("2001:db8:1::1", "IPv6")},
		{new_ip("2002:c633:6401::2", "IPv6"), new_ip("2001:db8:1::2", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "2001:db8:1::1", "prefer higher precedence");
	assert_equal(order[2].addr, "2002:c633:6401::1", "prefer higher precedence");
end
