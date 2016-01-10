-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local error = error;
local round_up = math.ceil;
local urandom, urandom_err = io.open("/dev/urandom", "r");

module "uuid"

local function get_nibbles(n)
	local binary_random = urandom:read(round_up(n/2));
	local hex_random = binary_random:gsub(".",
		function (x) return ("%02x"):format(x:byte()) end);
	return hex_random:sub(1, n);
end
local function get_twobits()
	return ("%x"):format(urandom:read(1):byte() % 4 + 8);
end

function generate()
	if not urandom then
		error("Unable to obtain a secure random number generator, please see https://prosody.im/doc/random ("..urandom_err..")");
	end
	-- generate RFC 4122 complaint UUIDs (version 4 - random)
	return get_nibbles(8).."-"..get_nibbles(4).."-4"..get_nibbles(3).."-"..(get_twobits())..get_nibbles(3).."-"..get_nibbles(12);
end

function seed()
end

return _M;
