-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


-- XEP-0082: XMPP Date and Time Profiles

local os_date = os.date;
local error = error;

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
	error("datetime.parse: Not implemented"); -- TODO
end

return _M;
