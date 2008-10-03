
local tonumber, tostring = tonumber, tostring;
local ipairs = ipairs;

local m_random = math.random;
local format = string.format;

local print = print;

local hosts = hosts;

local modulemanager = require "core.modulemanager";
local log = require "util.logger".init("sessionmanager");
local error = error;

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

function streamopened(session, attr)
						local send = session.send;
						session.host = attr.to or error("Client failed to specify destination hostname");
			                        session.version = tonumber(attr.version) or 0;
			                        session.streamid = m_random(1000000, 99999999);
			                        print(session, session.host, "Client opened stream");
			                        send("<?xml version='1.0'?>");
			                        send(format("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' id='%s' from='%s' version='1.0'>", session.streamid, session.host));
						
						local features = {};
						modulemanager.fire_event("stream-features", session, features);
						
						send("<stream:features>");
						
						for _, feature in ipairs(features) do
							send_to_session(session, tostring(features));
						end
 
        			                send("</stream:features>");
						log("info", "core", "Stream opened successfully");
						session.notopen = nil;
end

return _M;