-- Prosody IM
-- Copyright (C) 2008-2014 Matthew Wild
-- Copyright (C) 2008-2014 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local tostring = tostring;
local os_time = os.time;
local os_clock = os.clock;
local ceil = math.ceil;
local sha1 = require "util.hashes".sha1;

local last_uniq_time = 0;
local function uniq_time()
	local new_uniq_time = os_time();
	if last_uniq_time >= new_uniq_time then new_uniq_time = last_uniq_time + 1; end
	last_uniq_time = new_uniq_time;
	return new_uniq_time;
end

local function new_random(x)
	return sha1(x..os_clock()..tostring({}));
end

local buffer = new_random(uniq_time());

local function seed(x)
	buffer = new_random(buffer..x);
end

local function bytes(n)
	if #buffer < n then seed(uniq_time()); end
	local r = buffer:sub(0, n);
	buffer = buffer:sub(n+1);
	return r;
end

return {
	seed = seed;
	bytes = bytes;
};
