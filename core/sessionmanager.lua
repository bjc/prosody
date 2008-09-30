
local tostring = tostring;

local log = require "util.logger".init("sessionmanager");

module "sessionmanager"

function new_session(conn)
	local session = { conn = conn, notopen = true, priority = 0, type = "c2s_unauthed" };
	local w = conn.write;
	session.send = function (t) w(tostring(t)); end
	return session;
end

function send_to_session(session, data)
	log("debug", "Sending...", tostring(data));
	session.conn.write(tostring(data));
end

return _M;