-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


-- XEP-0082: XMPP Date and Time Profiles

local os_date = os.date;
local os_time = os.time;
local os_difftime = os.difftime;
local floor = math.floor;
local tonumber = tonumber;

local _ENV = nil;
-- luacheck: std none

local function date(t)
	return os_date("!%Y-%m-%d", t and floor(t) or nil);
end

local function datetime(t)
	if t == nil or t % 1 == 0 then
		return os_date("!%Y-%m-%dT%H:%M:%SZ", t);
	end
	local m = t % 1;
	local s = floor(t);
	return os_date("!%Y-%m-%dT%H:%M:%S.%%06dZ", s):format(floor(m * 1000000));
end

local function time(t)
	if t == nil or t % 1 == 0 then
		return os_date("!%H:%M:%S", t);
	end
	local m = t % 1;
	local s = floor(t);
	return os_date("!%H:%M:%S.%%06d", s):format(floor(m * 1000000));
end

local function legacy(t)
	return os_date("!%Y%m%dT%H:%M:%S", t and floor(t) or nil);
end

local function parse(s)
	if s then
		local year, month, day, hour, min, sec, tzd;
		year, month, day, hour, min, sec, tzd = s:match("^(%d%d%d%d)%-?(%d%d)%-?(%d%d)T(%d%d):(%d%d):(%d%d%.?%d*)([Z+%-]?.*)$");
		if year then
			local now = os_time();
			local time_offset = os_difftime(os_time(os_date("*t", now)), os_time(os_date("!*t", now))); -- to deal with local timezone
			local tzd_offset = 0;
			if tzd ~= "" and tzd ~= "Z" then
				local sign, h, m = tzd:match("([+%-])(%d%d):?(%d*)");
				if not sign then return; end
				if #m ~= 2 then m = "0"; end
				h, m = tonumber(h), tonumber(m);
				tzd_offset = h * 60 * 60 + m * 60;
				if sign == "-" then tzd_offset = -tzd_offset; end
			end
			local prec = sec%1;
			sec = floor(sec + time_offset) - tzd_offset;
			return os_time({year=year, month=month, day=day, hour=hour, min=min, sec=sec, isdst=false})+prec;
		end
	end
end

return {
	date     = date;
	datetime = datetime;
	time     = time;
	legacy   = legacy;
	parse    = parse;
};
