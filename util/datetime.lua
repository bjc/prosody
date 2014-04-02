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
local error = error;
local tonumber = tonumber;

module "datetime"

function date(t)
	return os_date("!%Y-%m-%d", t);
end

function datetime(t)
	return os_date("!%Y-%m-%dT%H:%M:%SZ", t);
end

function time(t)
	return os_date("!%H:%M:%S", t);
end

function legacy(t)
	return os_date("!%Y%m%dT%H:%M:%S", t);
end

function parse(s)
	if s then
		local year, month, day, hour, min, sec, tzd;
		year, month, day, hour, min, sec, tzd = s:match("^(%d%d%d%d)%-?(%d%d)%-?(%d%d)T(%d%d):(%d%d):(%d%d)%.?%d*([Z+%-]?.*)$");
		if year then
			local time_offset = os_difftime(os_time(os_date("*t")), os_time(os_date("!*t"))); -- to deal with local timezone
			local tzd_offset = 0;
			if tzd ~= "" and tzd ~= "Z" then
				local sign, h, m = tzd:match("([+%-])(%d%d):?(%d*)");
				if not sign then return; end
				if #m ~= 2 then m = "0"; end
				h, m = tonumber(h), tonumber(m);
				tzd_offset = h * 60 * 60 + m * 60;
				if sign == "-" then tzd_offset = -tzd_offset; end
			end
			sec = (sec + time_offset) - tzd_offset;
			return os_time({year=year, month=month, day=day, hour=hour, min=min, sec=sec, isdst=false});
		end
	end
end

return _M;
