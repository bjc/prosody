-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local tostring, setmetatable = tostring, setmetatable;
local pairs, next= pairs, next;

local hosts = hosts;
local full_sessions = full_sessions;
local bare_sessions = bare_sessions;

local logger = require "util.logger";
local log = logger.init("sessionmanager");
local rm_load_roster = require "core.rostermanager".load_roster;
local config_get = require "core.configmanager".get;
local resourceprep = require "util.encodings".stringprep.resourceprep;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local uuid_generate = require "util.uuid".generate;

local initialize_filters = require "util.filters".initialize;
local gettime = require "socket".gettime;

module "sessionmanager"

function new_session(conn)
	local session = { conn = conn, type = "c2s_unauthed", conntime = gettime() };
	local filter = initialize_filters(session);
	local w = conn.write;
	session.send = function (t)
		if t.name then
			t = filter("stanzas/out", t);
		end
		if t then
			t = filter("bytes/out", tostring(t));
			if t then
				return w(conn, t);
			end
		end
	end
	session.ip = conn:ip();
	local conn_name = "c2s"..tostring(session):match("[a-f0-9]+$");
	session.log = logger.init(conn_name);

	return session;
end

local resting_session = { -- Resting, not dead
		destroyed = true;
		type = "c2s_destroyed";
		close = function (session)
			session.log("debug", "Attempt to close already-closed session");
		end;
		filter = function (type, data) return data; end;
	}; resting_session.__index = resting_session;

function retire_session(session)
	local log = session.log or log;
	for k in pairs(session) do
		if k ~= "log" and k ~= "id" then
			session[k] = nil;
		end
	end

	function session.send(data) log("debug", "Discarding data sent to resting session: %s", tostring(data)); return false; end
	function session.data(data) log("debug", "Discarding data received from resting session: %s", tostring(data)); end
	return setmetatable(session, resting_session);
end

function destroy_session(session, err)
	(session.log or log)("debug", "Destroying session for %s (%s@%s)%s", session.full_jid or "(unknown)", session.username or "(unknown)", session.host or "(unknown)", err and (": "..err) or "");
	if session.destroyed then return; end

	-- Remove session/resource from user's session list
	if session.full_jid then
		local host_session = hosts[session.host];

		-- Allow plugins to prevent session destruction
		if host_session.events.fire_event("pre-resource-unbind", {session=session, error=err}) then
			return;
		end

		host_session.sessions[session.username].sessions[session.resource] = nil;
		full_sessions[session.full_jid] = nil;

		if not next(host_session.sessions[session.username].sessions) then
			log("debug", "All resources of %s are now offline", session.username);
			host_session.sessions[session.username] = nil;
			bare_sessions[session.username..'@'..session.host] = nil;
		end

		host_session.events.fire_event("resource-unbind", {session=session, error=err});
	end

	retire_session(session);
end

function make_authenticated(session, username)
	username = nodeprep(username);
	if not username or #username == 0 then return nil, "Invalid username"; end
	session.username = username;
	if session.type == "c2s_unauthed" then
		session.type = "c2s";
	end
	session.log("info", "Authenticated as %s@%s", username or "(unknown)", session.host or "(unknown)");
	return true;
end

-- returns true, nil on success
-- returns nil, err_type, err, err_message on failure
function bind_resource(session, resource)
	if not session.username then return nil, "auth", "not-authorized", "Cannot bind resource before authentication"; end
	if session.resource then return nil, "cancel", "already-bound", "Cannot bind multiple resources on a single connection"; end
	-- We don't support binding multiple resources

	resource = resourceprep(resource);
	resource = resource ~= "" and resource or uuid_generate();
	--FIXME: Randomly-generated resources must be unique per-user, and never conflict with existing

	if not hosts[session.host].sessions[session.username] then
		local sessions = { sessions = {} };
		hosts[session.host].sessions[session.username] = sessions;
		bare_sessions[session.username..'@'..session.host] = sessions;
	else
		local sessions = hosts[session.host].sessions[session.username].sessions;
		if sessions[resource] then
			-- Resource conflict
			local policy = config_get(session.host, "conflict_resolve");
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
					bare_sessions[session.username.."@"..session.host] = hosts[session.host].sessions[session.username];
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
	full_sessions[session.full_jid] = session;

	local err;
	session.roster, err = rm_load_roster(session.username, session.host);
	if err then
		full_sessions[session.full_jid] = nil;
		hosts[session.host].sessions[session.username].sessions[resource] = nil;
		session.full_jid = nil;
		session.resource = nil;
		if next(bare_sessions[session.username..'@'..session.host].sessions) == nil then
			bare_sessions[session.username..'@'..session.host] = nil;
			hosts[session.host].sessions[session.username] = nil;
		end
		session.log("error", "Roster loading failed: %s", err);
		return nil, "cancel", "internal-server-error", "Error loading roster";
	end

	hosts[session.host].events.fire_event("resource-bind", {session=session});

	return true;
end

function send_to_available_resources(user, host, stanza)
	local jid = user.."@"..host;
	local count = 0;
	local user = bare_sessions[jid];
	if user then
		for k, session in pairs(user.sessions) do
			if session.presence then
				session.send(stanza);
				count = count + 1;
			end
		end
	end
	return count;
end

function send_to_interested_resources(user, host, stanza)
	local jid = user.."@"..host;
	local count = 0;
	local user = bare_sessions[jid];
	if user then
		for k, session in pairs(user.sessions) do
			if session.interested then
				session.send(stanza);
				count = count + 1;
			end
		end
	end
	return count;
end

return _M;
