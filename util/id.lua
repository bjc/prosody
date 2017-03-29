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
	short =  function () return b64url_random(6); end;
	medium = function () return b64url_random(12); end;
	long =   function () return b64url_random(24); end;
	custom = function (size)
		return function () return b64url_random(size); end;
	end;
}
