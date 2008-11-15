
local tonumber, tostring = tonumber, tostring;
local ipairs, pairs, print, next= ipairs, pairs, print, next;
local collectgarbage = collectgarbage;
local m_random = import("math", "random");
local format = import("string", "format");

local hosts = hosts;
local sessions = sessions;

local modulemanager = require "core.modulemanager";
local log = require "util.logger".init("sessionmanager");
local error = error;
local uuid_generate = require "util.uuid".generate;
local rm_load_roster = require "core.rostermanager".load_roster;

local newproxy = newproxy;
local getmetatable = getmetatable;

module "sessionmanager"

local open_sessions = 0;

function new_session(conn)
	local session = { conn = conn,  priority = 0, type = "c2s_unauthed" };
	if true then
		session.trace = newproxy(true);
		getmetatable(session.trace).__gc = function () open_sessions = open_sessions - 1; print("Session got collected, now "..open_sessions.." sessions are allocated") end;
	end
	open_sessions = open_sessions + 1;
	local w = conn.write;
	session.send = function (t) w(tostring(t)); end
	return session;
end

function destroy_session(session)
	(session.log or log)("info", "Destroying session");
	if session.host and session.username then
		if session.resource then
			hosts[session.host].sessions[session.username].sessions[session.resource] = nil;
		end
		if hosts[session.host] and hosts[session.host].sessions[session.username] then
			if not next(hosts[session.host].sessions[session.username].sessions) then
				log("debug", "All resources of %s are now offline", session.username);
				hosts[session.host].sessions[session.username] = nil;
			end
		end
	end
	session.conn = nil;
	session.disconnect = nil;
	for k in pairs(session) do
		if k ~= "trace" then
			session[k] = nil;
		end
	end
end

function send_to_session(session, data)
	log("debug", "Sending: %s", tostring(data));
	session.conn.write(tostring(data));
end

function make_authenticated(session, username)
	session.username = username;
	if session.type == "c2s_unauthed" then
		session.type = "c2s";
	end
	return true;
end

-- returns true, nil on success
-- returns nil, err_type, err, err_message on failure
function bind_resource(session, resource)
	if not session.username then return nil, "auth", "not-authorized", "Cannot bind resource before authentication"; end
	if session.resource then return nil, "cancel", "already-bound", "Cannot bind multiple resources on a single connection"; end
	-- We don't support binding multiple resources

	resource = resource or uuid_generate();
	--FIXME: Randomly-generated resources must be unique per-user, and never conflict with existing
	
	if not hosts[session.host].sessions[session.username] then
		hosts[session.host].sessions[session.username] = { sessions = {} };
	else
		if hosts[session.host].sessions[session.username].sessions[resource] then
			-- Resource conflict
			return nil, "cancel", "conflict", "Resource already exists"; -- TODO kick old resource
		end
	end
	
	session.resource = resource;
	session.full_jid = session.username .. '@' .. session.host .. '/' .. resource;
	hosts[session.host].sessions[session.username].sessions[resource] = session;
	
	session.roster = rm_load_roster(session.username, session.host);
	
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
							send(tostring(feature));
						end
 
        			                send("</stream:features>");
						log("info", "Stream opened successfully");
						session.notopen = nil;
end

function send_to_available_resources(user, host, stanza)
	local count = 0;
	local to = stanza.attr.to;
	stanza.attr.to = nil;
	local h = hosts[host];
	if h and h.type == "local" then
		local u = h.sessions[user];
		if u then
			for k, session in pairs(u.sessions) do
				if session.presence then
					session.send(stanza);
					count = count + 1;
				end
			end
		end
	end
	stanza.attr.to = to;
	return count;
end

return _M;