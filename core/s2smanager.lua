-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local hosts = prosody.hosts;
local tostring, pairs, setmetatable
    = tostring, pairs, setmetatable;

local logger_init = require "util.logger".init;

local log = logger_init("s2smanager");

local prosody = _G.prosody;
incoming_s2s = {};
prosody.incoming_s2s = incoming_s2s;
local incoming_s2s = incoming_s2s;
local fire_event = prosody.events.fire_event;

module "s2smanager"

function new_incoming(conn)
	local session = { conn = conn, type = "s2sin_unauthed", direction = "incoming", hosts = {} };
	session.log = logger_init("s2sin"..tostring(session):match("[a-f0-9]+$"));
	incoming_s2s[session] = true;
	return session;
end

function new_outgoing(from_host, to_host)
	local host_session = { to_host = to_host, from_host = from_host, host = from_host,
		               notopen = true, type = "s2sout_unauthed", direction = "outgoing" };
	hosts[from_host].s2sout[to_host] = host_session;
	local conn_name = "s2sout"..tostring(host_session):match("[a-f0-9]*$");
	host_session.log = logger_init(conn_name);
	return host_session;
end

local resting_session = { -- Resting, not dead
		destroyed = true;
		type = "s2s_destroyed";
		open_stream = function (session)
			session.log("debug", "Attempt to open stream on resting session");
		end;
		close = function (session)
			session.log("debug", "Attempt to close already-closed session");
		end;
		filter = function (type, data) return data; end;
	}; resting_session.__index = resting_session;

function retire_session(session, reason)
	local log = session.log or log;
	for k in pairs(session) do
		if k ~= "log" and k ~= "id" and k ~= "conn" then
			session[k] = nil;
		end
	end

	session.destruction_reason = reason;

	function session.send(data) log("debug", "Discarding data sent to resting session: %s", tostring(data)); end
	function session.data(data) log("debug", "Discarding data received from resting session: %s", tostring(data)); end
	session.sends2s = session.send;
	return setmetatable(session, resting_session);
end

function destroy_session(session, reason)
	if session.destroyed then return; end
	(session.log or log)("debug", "Destroying "..tostring(session.direction).." session "..tostring(session.from_host).."->"..tostring(session.to_host)..(reason and (": "..reason) or ""));
	
	if session.direction == "outgoing" then
		hosts[session.from_host].s2sout[session.to_host] = nil;
		session:bounce_sendq(reason);
	elseif session.direction == "incoming" then
		incoming_s2s[session] = nil;
	end
	
	local event_data = { session = session, reason = reason };
	if session.type == "s2sout" then
		fire_event("s2sout-destroyed", event_data);
		if hosts[session.from_host] then
			hosts[session.from_host].events.fire_event("s2sout-destroyed", event_data);
		end
	elseif session.type == "s2sin" then
		fire_event("s2sin-destroyed", event_data);
		if hosts[session.to_host] then
			hosts[session.to_host].events.fire_event("s2sin-destroyed", event_data);
		end
	end
	
	retire_session(session, reason); -- Clean session until it is GC'd
	return true;
end

return _M;
