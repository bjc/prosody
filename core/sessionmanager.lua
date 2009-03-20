-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



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
local config_get = require "core.configmanager".get;

local fire_event = require "core.eventmanager".fire_event;

local gettime = require "socket".gettime;

local st = require "util.stanza";

local newproxy = newproxy;
local getmetatable = getmetatable;

module "sessionmanager"

local open_sessions = 0;

function new_session(conn)
	local session = { conn = conn,  priority = 0, type = "c2s_unauthed", conntime = gettime() };
	if true then
		session.trace = newproxy(true);
		getmetatable(session.trace).__gc = function () open_sessions = open_sessions - 1; end;
	end
	open_sessions = open_sessions + 1;
	log("info", "open sessions now: ".. open_sessions);
	local w = conn.write;
	session.send = function (t) w(tostring(t)); end
	session.ip = conn.ip();
	return session;
end

function destroy_session(session, err)
	(session.log or log)("info", "Destroying session");
	
	-- Send unavailable presence
	if session.presence then
		local pres = st.presence{ type = "unavailable" };
		if (not err) or err == "closed" then err = "connection closed"; end
		pres:tag("status"):text("Disconnected: "..err);
		session:dispatch_stanza(pres);
	end
	
	-- Remove session/resource from user's session list
	if session.host and session.username then
		-- FIXME: How can the below ever be nil? (but they sometimes are...)
		if hosts[session.host] and hosts[session.host].sessions[session.username] then
			if session.resource then
				hosts[session.host].sessions[session.username].sessions[session.resource] = nil;
			end
				
			if not next(hosts[session.host].sessions[session.username].sessions) then
				log("debug", "All resources of %s are now offline", session.username);
				hosts[session.host].sessions[session.username] = nil;
			end
		else
			log("error", "host or session table didn't exist, please report this! Host: %s [%s] Sessions: %s [%s]", 
					tostring(hosts[session.host]), tostring(session.host),
					tostring(hosts[session.host].sessions[session.username] ), tostring(session.username));
		end
	end
	
	for k in pairs(session) do
		if k ~= "trace" then
			session[k] = nil;
		end
	end
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
		local sessions = hosts[session.host].sessions[session.username].sessions;
		local limit = config_get(session.host, "core", "max_resources") or 10;
		if #sessions >= limit then
			return nil, "cancel", "conflict", "Resource limit reached; only "..limit.." resources allowed";
		end
		if sessions[resource] then
			-- Resource conflict
			local policy = config_get(session.host, "core", "conflict_resolve");
			local increment;
			if policy == "random" then
				resource = uuid_generate();
				increment = true;
			elseif policy == "increment" then
				increment = true; -- TODO ping old resource
			elseif policy == "kick_new" then
				return nil, "cancel", "conflict", "Resource already exists";
			else -- if policy == "kick_old" then
				sessions[resource]:close {
					condition = "conflict";
					text = "Replaced by new connection";
				};
				if not next(sessions) then
					hosts[session.host].sessions[session.username] = { sessions = sessions };
				end
			end
			if increment and sessions[resource] then
				local count = 1;
				while sessions[resource.."#"..count] do
					count = count + 1;
				end
				resource = resource.."#"..count;
			end
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
			                        (session.log or session)("debug", "Client sent opening <stream:stream> to %s", session.host);
			                        
						
						send("<?xml version='1.0'?>");
			                        send(format("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' id='%s' from='%s' version='1.0'>", session.streamid, session.host));
						
						if not hosts[session.host] then
							-- We don't serve this host...
							session:close{ condition = "host-unknown", text = "This server does not serve "..tostring(session.host)};
							return;
						end
						
						
						local features = st.stanza("stream:features");
						fire_event("stream-features", session, features);
						
						send(features);
						
						(session.log or log)("info", "Sent reply <stream:stream> to client");
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
