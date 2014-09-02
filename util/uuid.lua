-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local random = require "util.random";
local random_bytes = random.bytes;
local hex = require "util.hex".to;
local m_ceil = math.ceil;

local function get_nibbles(n)
	return hex(random_bytes(m_ceil(n/2))):sub(1, n);
end

local function get_twobits()
	return ("%x"):format(get_nibbles(1):byte() % 4 + 8);
end

local function generate()
	-- generate RFC 4122 complaint UUIDs (version 4 - random)
	return get_nibbles(8).."-"..get_nibbles(4).."-4"..get_nibbles(3).."-"..(get_twobits())..get_nibbles(3).."-"..get_nibbles(12);
end

return {
	get_nibbles=get_nibbles;
	generate = generate ;
	-- COMPAT
	seed = random.seed;
};
