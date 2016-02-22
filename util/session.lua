local initialize_filters = require "util.filters".initialize;
local logger = require "util.logger";

local function new_session(typ)
	local session = {
		type = typ .. "_unauthed";
	};
	return session;
end

local function set_id(session)
	local id = session.type .. tostring(session):match("%x+$"):lower();
	session.id = id;
	return session;
end

local function set_logger(session)
	local log = logger.init(session.id);
	session.log = log;
	return session;
end

local function set_conn(session, conn)
	session.conn = conn;
	session.ip = conn:ip();
	return session;
end

local function set_send(session)
	local conn = session.conn;
	if not conn then
		function session.send(data)
			session.log("debug", "Discarding data sent to unconnected session: %s", tostring(data));
			return false;
		end
		return session;
	end
	local filter = initialize_filters(session);
	local w = conn.write;
	session.send = function (t)
		if t.name then
			t = filter("stanzas/out", t);
		end
		if t then
			t = filter("bytes/out", tostring(t));
			if t then
				local ret, err = w(conn, t);
				if not ret then
					session.log("debug", "Error writing to connection: %s", tostring(err));
					return false, err;
				end
			end
		end
		return true;
	end
	return session;
end

return {
	new = new_session;
	set_id = set_id;
	set_logger = set_logger;
	set_conn = set_conn;
	set_send = set_send;
}
