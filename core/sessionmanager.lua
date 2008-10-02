
local tostring = tostring;

local print = print;

local hosts = hosts;

local log = require "util.logger".init("sessionmanager");

module "sessionmanager"

function new_session(conn)
	local session = { conn = conn, notopen = true, priority = 0, type = "c2s_unauthed" };
	local w = conn.write;
	session.send = function (t) w(tostring(t)); end
	return session;
end

function destroy_session(session)
end

function send_to_session(session, data)
	log("debug", "Sending: %s", tostring(data));
	session.conn.write(tostring(data));
end

function make_authenticated(session, username)
	session.username = username;
	session.resource = resource;
	if session.type == "c2s_unauthed" then
		session.type = "c2s";
	end
end

function bind_resource(session, resource)
	if not session.username then return false, "auth"; end
	if session.resource then return false, "constraint"; end -- We don't support binding multiple resources
	resource = resource or math.random(100000, 99999999); -- FIXME: Clearly we have issues :)
	--FIXME: Randomly-generated resources must be unique per-user, and never conflict with existing
	
	if not hosts[session.host].sessions[session.username] then
		hosts[session.host].sessions[session.username] = { sessions = {} };
	else
		if hosts[session.host].sessions[session.username].sessions[resource] then
			-- Resource conflict
			return false, "conflict";
		end
	end
	
	session.resource = resource;
	session.full_jid = session.username .. '@' .. session.host .. '/' .. resource;
	hosts[session.host].sessions[session.username].sessions[resource] = session;
	
	return true;
end

return _M;