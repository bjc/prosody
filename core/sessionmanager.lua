
local tonumber, tostring = tonumber, tostring;
local ipairs, pairs, print= ipairs, pairs, print;
local collectgarbage = collectgarbage;
local m_random = import("math", "random");
local format = import("string", "format");

local hosts = hosts;
local sessions = sessions;

local modulemanager = require "core.modulemanager";
local log = require "util.logger".init("sessionmanager");
local error = error;
local uuid_generate = require "util.uuid".uuid_generate;

local newproxy = newproxy;
local getmetatable = getmetatable;

module "sessionmanager"

function new_session(conn)
	local session = { conn = conn, notopen = true, priority = 0, type = "c2s_unauthed" };
	if true then
		session.trace = newproxy(true);
		getmetatable(session.trace).__gc = function () print("Session got collected") end;
	end
	local w = conn.write;
	session.send = function (t) w(tostring(t)); end
	return session;
end

function destroy_session(session)
	if not (session and session.disconnect) then return; end 
	log("debug", "Destroying session...");
	session.disconnect();
	if session.username then
		if session.resource then
			hosts[session.host].sessions[session.username].sessions[session.resource] = nil;
		end
		local nomore = true;
		for res, ssn in pairs(hosts[session.host].sessions[session.username]) do
			nomore = false;
		end
		if nomore then
			hosts[session.host].sessions[session.username] = nil;
		end
	end
	session.conn = nil;
	session.disconnect = nil;
	for k in pairs(session) do
		if k ~= "trace" then
			session[k] = nil;
		end
	end
	collectgarbage("collect");
	collectgarbage("collect");
	collectgarbage("collect");
	collectgarbage("collect");
	collectgarbage("collect");
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
	return true;
end

function bind_resource(session, resource)
	if not session.username then return false, "auth"; end
	if session.resource then return false, "constraint"; end -- We don't support binding multiple resources
	resource = resource or uuid_generate();
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
							send_to_session(session, tostring(feature));
						end
 
        			                send("</stream:features>");
						log("info", "Stream opened successfully");
						session.notopen = nil;
end

return _M;