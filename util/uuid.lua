-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local random = require "prosody.util.random";
local random_bytes = random.bytes;
local time = require "prosody.util.time";
local hex = require "prosody.util.hex".encode;
local m_ceil = math.ceil;
local m_floor = math.floor;

local function get_nibbles(n)
	return hex(random_bytes(m_ceil(n/2))):sub(1, n);
end

local function get_twobits()
	return ("%x"):format(random_bytes(1):byte() % 4 + 8);
end

local function generate()
	-- generate RFC 4122 complaint UUIDs (version 4 - random)
	return get_nibbles(8).."-"..get_nibbles(4).."-4"..get_nibbles(3).."-"..(get_twobits())..get_nibbles(3).."-"..get_nibbles(12);
end

local function generate_v7()
	-- Sortable based on time and random
	-- https://datatracker.ietf.org/doc/html/draft-peabody-dispatch-new-uuid-format-01#section-4.4
	local t = time.now();
	local unixts = m_floor(t);
	local unixts_a = m_floor(unixts / 16);
	local unixts_b = m_floor(unixts % 16);
	local subsec = t % 1;
	local subsec_a = m_floor(subsec * 0x1000);
	local subsec_b = m_floor(subsec * 0x1000000) % 0x1000;
	return ("%08x-%x%03x-7%03x-%4s-%12s"):format(unixts_a, unixts_b, subsec_a, subsec_b, get_twobits() .. get_nibbles(3), get_nibbles(12));
end

return {
	v4 = generate;
	v7 = generate_v7;
	get_nibbles=get_nibbles;
	generate = generate ;
	-- COMPAT
	seed = random.seed;
};
