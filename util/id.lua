-- Prosody IM
-- Copyright (C) 2008-2017 Matthew Wild
-- Copyright (C) 2008-2017 Waqas Hussain
-- Copyright (C) 2008-2017 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local s_gsub = string.gsub;
local random_bytes = require "util.random".bytes;
local base64_encode = require "util.encodings".base64.encode;

local b64url = { ["+"] = "-", ["/"] = "_", ["="] = "" };
local function b64url_random(len)
	return (s_gsub(base64_encode(random_bytes(len)), "[+/=]", b64url));
end

return {
	-- sizes divisible by 3 fit nicely into base64 without padding==

	-- for short lived things with low risk of collisions
	tiny = function() return b64url_random(3); end;

	-- close to 8 bytes, should be good enough for relatively short lived or uses
	-- scoped by host or users, half the size of an uuid
	short = function() return b64url_random(9); end;

	-- more entropy than uuid at 2/3 the size
	-- should be okay for globally scoped ids or security token
	medium = function() return b64url_random(18); end;

	-- as long as an uuid but MOAR entropy
	long = function() return b64url_random(27); end;

	-- pick your own adventure
	custom = function (size)
		return function () return b64url_random(size); end;
	end;
}
