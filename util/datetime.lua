-- XEP-0082: XMPP Date and Time Profiles

local os_date = os.date;
local error = error;

module "datetime"

function date()
	return os_date("!%Y-%m-%d");
end

function datetime()
	return os_date("!%Y-%m-%dT%H:%M:%SZ");
end

function time()
	return os_date("!%H:%M:%S");
end

function legacy()
	return os_date("!%Y%m%dT%H:%M:%S");
end

function parse(s)
	error("datetime.parse: Not implemented"); -- TODO
end

return _M;
