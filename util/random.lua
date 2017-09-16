-- Prosody IM
-- Copyright (C) 2008-2014 Matthew Wild
-- Copyright (C) 2008-2014 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local ok, crand = pcall(require, "util.crand");
if ok then return crand; end

local urandom, urandom_err = io.open("/dev/urandom", "r");

local function bytes(n)
	return urandom:read(n);
end

if not urandom then
	function bytes()
		error("Unable to obtain a secure random number generator, please see https://prosody.im/doc/random ("..urandom_err..")");
	end
end

return {
	bytes = bytes;
};
