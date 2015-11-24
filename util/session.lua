local logger = require "util.logger";

local function new_session(typ)
	local session = {
		type = typ .. "_unauthed";
	};
	return session;
end

local function set_id(session)
	local id = typ .. tostring(session):match("%x+$"):lower();
	session.id = id;
	return session;
end

local function set_logger(session)
	local log = logger.init(id);
	session.log = log;
	return session;
end

return {
	new = new_session;
	set_id = set_id;
	set_logger = set_logger;
}
