-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local m_random = math.random;
local tostring = tostring;
local os_time = os.time;
local os_clock = os.clock;
local sha1 = require "util.hashes".sha1;

module "uuid"

local last_uniq_time = 0;
local function uniq_time()
	local new_uniq_time = os_time();
	if last_uniq_time >= new_uniq_time then new_uniq_time = last_uniq_time + 1; end
	last_uniq_time = new_uniq_time;
	return new_uniq_time;
end

local function new_random(x)
	return sha1(x..os_clock()..tostring({}), true);
end

function generate()
	return new_random(uniq_time());
end

return _M;
