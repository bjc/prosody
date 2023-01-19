-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: globals prosody.full_sessions prosody.bare_sessions

local tostring, setmetatable = tostring, setmetatable;
local pairs, next= pairs, next;

local hosts = prosody.hosts;
local full_sessions = prosody.full_sessions;
local bare_sessions = prosody.bare_sessions;

local logger = require "util.logger";
local log = logger.init("sessionmanager");
local rm_load_roster = require "core.rostermanager".load_roster;
local config_get = require "core.configmanager".get;
local resourceprep = require "util.encodings".stringprep.resourceprep;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local generate_identifier = require "util.id".short;
local sessionlib = require "util.session";

local initialize_filters = require "util.filters".initialize;
local gettime = require "socket".gettime;

local _ENV = nil;
-- luacheck: std none

local function new_session(conn)
	local session = sessionlib.new("c2s");
	sessionlib.set_id(session);
	sessionlib.set_logger(session);
	sessionlib.set_conn(session, conn);

	session.conntime = gettime();
	local filter = initialize_filters(session);
	local w = conn.write;

	function session.rawsend(t)
		t = filter("bytes/out", tostring(t));
		if t then
			local ret, err = w(conn, t);
			if not ret then
				session.log("debug", "Error writing to connection: %s", err);
				return false, err;
			end
		end
		return true;
	end

	session.send = function (t)
		session.log("debug", "Sending[%s]: %s", session.type, t.top_tag and t:top_tag() or t:match("^[^>]*>?"));
		if t.name then
			t = filter("stanzas/out", t);
		end
		if t then
			return session.rawsend(t);
		end
		return true;
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
		filter = function (type, data) return data; end; --luacheck: ignore 212/type
	}; resting_session.__index = resting_session;

local function retire_session(session)
	local log = session.log or log; --luacheck: ignore 431/log
	for k in pairs(session) do
		if k ~= "log" and k ~= "id" then
			session[k] = nil;
		end
	end

	function session.send(data) log("debug", "Discarding data sent to resting session: %s", data); return false; end
	function session.rawsend(data) log("debug", "Discarding data sent to resting session: %s", data); return false; end
	function session.data(data) log("debug", "Discarding data received from resting session: %s", data); end
	session.thread = { run = function (_, data) return session.data(data) end };
	return setmetatable(session, resting_session);
end

local function destroy_session(session, err)
	if session.destroyed then return; end
	(session.log or log)("debug", "Destroying session for %s (%s@%s)%s",
		session.full_jid or "(unknown)", session.username or "(unknown)",
		session.host or "(unknown)", err and (": "..err) or "");

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

local function make_authenticated(session, username, scope)
	username = nodeprep(username);
	if not username or #username == 0 then return nil, "Invalid username"; end
	session.username = username;
	if session.type == "c2s_unauthed" then
		session.type = "c2s_unbound";
	end
	session.auth_scope = scope;
	session.log("info", "Authenticated as %s@%s", username, session.host or "(unknown)");
	return true;
end

-- returns true, nil on success
-- returns nil, err_type, err, err_message on failure
local function bind_resource(session, resource)
	if not session.username then return nil, "auth", "not-authorized", "Cannot bind resource before authentication"; end
	if session.resource then return nil, "cancel", "not-allowed", "Cannot bind multiple resources on a single connection"; end
	-- We don't support binding multiple resources

	local event_payload = { session = session, resource = resource };
	if hosts[session.host].events.fire_event("pre-resource-bind", event_payload) == false then
		local err = event_payload.error;
		if err then return nil, err.type, err.condition, err.text; end
		return nil, "cancel", "not-allowed";
	else
		-- In case a plugin wants to poke at it
		resource = event_payload.resource;
	end

	resource = resourceprep(resource or "", true);
	resource = resource ~= "" and resource or generate_identifier();
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
				resource = generate_identifier();
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
	if session.type == "c2s_unbound" then
		session.type = "c2s";
	end

	local err;
	session.roster, err = rm_load_roster(session.username, session.host);
	if err then
		-- FIXME: Why is all this rollback down here, instead of just doing the roster test up above?
		full_sessions[session.full_jid] = nil;
		hosts[session.host].sessions[session.username].sessions[resource] = nil;
		session.full_jid = nil;
		session.resource = nil;
		if session.type == "c2s" then
			session.type = "c2s_unbound";
		end
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

local function send_to_available_resources(username, host, stanza)
	local jid = username.."@"..host;
	local count = 0;
	local user = bare_sessions[jid];
	if user then
		for _, session in pairs(user.sessions) do
			if session.presence then
				session.send(stanza);
				count = count + 1;
			end
		end
	end
	return count;
end

local function send_to_interested_resources(username, host, stanza)
	local jid = username.."@"..host;
	local count = 0;
	local user = bare_sessions[jid];
	if user then
		for _, session in pairs(user.sessions) do
			if session.interested then
				session.send(stanza);
				count = count + 1;
			end
		end
	end
	return count;
end

return {
	new_session = new_session;
	retire_session = retire_session;
	destroy_session = destroy_session;
	make_authenticated = make_authenticated;
	bind_resource = bind_resource;
	send_to_available_resources = send_to_available_resources;
	send_to_interested_resources = send_to_interested_resources;
};
