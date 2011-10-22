-- Prosody IM
-- Copyright (C) 2011 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

function source(source)
	local new_ip = require"util.ip".new_ip;
	assert_equal(source(new_ip("2001::1", "IPv6"), {new_ip("3ffe::1", "IPv6"), new_ip("fe80::1", "IPv6")}).addr, "3ffe::1", "prefer appropriate scope");
	assert_equal(source(new_ip("2001::1", "IPv6"), {new_ip("fe80::1", "IPv6"), new_ip("fec0::1", "IPv6")}).addr, "fec0::1", "prefer appropriate scope");
	assert_equal(source(new_ip("fec0::1", "IPv6"), {new_ip("fe80::1", "IPv6"), new_ip("2001::1", "IPv6")}).addr, "2001::1", "prefer appropriate scope");
	assert_equal(source(new_ip("ff05::1", "IPv6"), {new_ip("fe80::1", "IPv6"), new_ip("fec0::1", "IPv6"), new_ip("2001::1", "IPv6")}).addr, "fec0::1", "prefer appropriate scope");
	assert_equal(source(new_ip("2001::1", "IPv6"), {new_ip("2001::1", "IPv6"), new_ip("2002::1", "IPv6")}).addr, "2001::1", "prefer same address");
	assert_equal(source(new_ip("fec0::1", "IPv6"), {new_ip("fec0::2", "IPv6"), new_ip("2001::1", "IPv6")}).addr, "fec0::2", "prefer appropriate scope");
	assert_equal(source(new_ip("2001::1", "IPv6"), {new_ip("2001::2", "IPv6"), new_ip("3ffe::2", "IPv6")}).addr, "2001::2", "longest matching prefix");
	assert_equal(source(new_ip("2002:836b:2179::1", "IPv6"), {new_ip("2002:836b:2179::d5e3:7953:13eb:22e8", "IPv6"), new_ip("2001::2", "IPv6")}).addr, "2002:836b:2179::d5e3:7953:13eb:22e8", "prefer matching label");
end

function destination(dest)
	local order;
	local new_ip = require"util.ip".new_ip;
	order = dest({new_ip("2001::1", "IPv6"), new_ip("131.107.65.121", "IPv4")}, {new_ip("2001::2", "IPv6"), new_ip("fe80::1", "IPv6"), new_ip("169.254.13.78", "IPv4")})
	assert_equal(order[1].addr, "2001::1", "prefer matching scope");
	assert_equal(order[2].addr, "131.107.65.121", "prefer matching scope")

	order = dest({new_ip("2001::1", "IPv6"), new_ip("131.107.65.121", "IPv4")}, {new_ip("fe80::1", "IPv6"), new_ip("131.107.65.117", "IPv4")})
	assert_equal(order[1].addr, "131.107.65.121", "prefer matching scope")
	assert_equal(order[2].addr, "2001::1", "prefer matching scope")

	order = dest({new_ip("2001::1", "IPv6"), new_ip("10.1.2.3", "IPv4")}, {new_ip("2001::2", "IPv6"), new_ip("fe80::1", "IPv6"), new_ip("10.1.2.4", "IPv4")})
	assert_equal(order[1].addr, "2001::1", "prefer higher precedence");
	assert_equal(order[2].addr, "10.1.2.3", "prefer higher precedence");

	order = dest({new_ip("2001::1", "IPv6"), new_ip("fec0::1", "IPv6"), new_ip("fe80::1", "IPv6")}, {new_ip("2001::2", "IPv6"), new_ip("fec0::1", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "fe80::1", "prefer smaller scope");
	assert_equal(order[2].addr, "fec0::1", "prefer smaller scope");
	assert_equal(order[3].addr, "2001::1", "prefer smaller scope");

	order = dest({new_ip("2001::1", "IPv6"), new_ip("3ffe::1", "IPv6")}, {new_ip("2001::2", "IPv6"), new_ip("3f44::2", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "2001::1", "longest matching prefix");
	assert_equal(order[2].addr, "3ffe::1", "longest matching prefix");

	order = dest({new_ip("2002:836b:4179::1", "IPv6"), new_ip("2001::1", "IPv6")}, {new_ip("2002:836b:4179::2", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "2002:836b:4179::1", "prefer matching label");
	assert_equal(order[2].addr, "2001::1", "prefer matching label");

	order = dest({new_ip("2002:836b:4179::1", "IPv6"), new_ip("2001::1", "IPv6")}, {new_ip("2002:836b:4179::2", "IPv6"), new_ip("2001::2", "IPv6"), new_ip("fe80::2", "IPv6")})
	assert_equal(order[1].addr, "2001::1", "prefer higher precedence");
	assert_equal(order[2].addr, "2002:836b:4179::1", "prefer higher precedence");
end
