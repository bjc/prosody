-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local gmatch = string.gmatch;
local t_concat, t_insert = table.concat, table.insert;
local to_byte, to_char = string.byte, string.char;

local function _latin1toutf8(str)
	if not str then return str; end
	local p = {};
	for ch in gmatch(str, ".") do
		ch = to_byte(ch);
		if (ch < 0x80) then
			t_insert(p, to_char(ch));
		elseif (ch < 0xC0) then
			t_insert(p, to_char(0xC2, ch));
		else
			t_insert(p, to_char(0xC3, ch - 64));
		end
	end
	return t_concat(p);
end

function latin1toutf8()
	local function assert_utf8(latin, utf8)
			assert_equal(_latin1toutf8(latin), utf8, "Incorrect UTF8 from Latin1: "..tostring(latin));
	end
	
	assert_utf8("", "")
	assert_utf8("test", "test")
	assert_utf8(nil, nil)
	assert_utf8("foobar.r\229kat.se", "foobar.r\195\165kat.se")
end
