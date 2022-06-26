-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local hosts = prosody.hosts;
local pairs, setmetatable = pairs, setmetatable;

local logger_init = require "util.logger".init;
local sessionlib = require "util.session";

local log = logger_init("s2smanager");

local prosody = _G.prosody;
local incoming_s2s = {};
_G.incoming_s2s = incoming_s2s;
prosody.incoming_s2s = incoming_s2s;
local fire_event = prosody.events.fire_event;

local _ENV = nil;
-- luacheck: std none

local function new_incoming(conn)
	local host_session = sessionlib.new("s2sin");
	sessionlib.set_id(host_session);
	sessionlib.set_logger(host_session);
	sessionlib.set_conn(host_session, conn);
	host_session.direction = "incoming";
	host_session.incoming = true;
	host_session.hosts = {};
	incoming_s2s[host_session] = true;
	return host_session;
end

local function new_outgoing(from_host, to_host)
	local host_session = sessionlib.new("s2sout");
	sessionlib.set_id(host_session);
	sessionlib.set_logger(host_session);
	host_session.to_host = to_host;
	host_session.from_host = from_host;
	host_session.host = from_host;
	host_session.notopen = true;
	host_session.direction = "outgoing";
	host_session.outgoing = true;
	host_session.hosts = {};
	hosts[from_host].s2sout[to_host] = host_session;
	return host_session;
end

local resting_session = { -- Resting, not dead
		destroyed = true;
		type = "s2s_destroyed";
		direction = "destroyed";
		open_stream = function (session)
			session.log("debug", "Attempt to open stream on resting session");
		end;
		close = function (session)
			session.log("debug", "Attempt to close already-closed session");
		end;
		reset_stream = function (session)
			session.log("debug", "Attempt to reset stream of already-closed session");
		end;
		filter = function (type, data) return data; end; --luacheck: ignore 212/type
	}; resting_session.__index = resting_session;

local function retire_session(session, reason)
	local log = session.log or log; --luacheck: ignore 431/log
	for k in pairs(session) do
		if k ~= "log" and k ~= "id" and k ~= "conn" then
			session[k] = nil;
		end
	end

	session.destruction_reason = reason;

	function session.send(data) log("debug", "Discarding data sent to resting session: %s", data); end
	function session.data(data) log("debug", "Discarding data received from resting session: %s", data); end
	session.thread = { run = function (_, data) return session.data(data) end };
	session.sends2s = session.send;
	return setmetatable(session, resting_session);
end

local function destroy_session(session, reason, bounce_reason)
	if session.destroyed then return; end
	local log = session.log or log;
	log("debug", "Destroying %s session %s->%s%s%s", session.direction, session.from_host, session.to_host, reason and ": " or "", reason or "");

	if session.direction == "outgoing" then
		hosts[session.from_host].s2sout[session.to_host] = nil;
		session:bounce_sendq(bounce_reason or reason);
	elseif session.direction == "incoming" then
		if session.outgoing and hosts[session.to_host].s2sout[session.from_host] == session then
			hosts[session.to_host].s2sout[session.from_host] = nil;
		end
		incoming_s2s[session] = nil;
	end

	local event_data = { session = session, reason = reason };
	fire_event("s2s-destroyed", event_data);
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

return {
	incoming_s2s = incoming_s2s;
	new_incoming = new_incoming;
	new_outgoing = new_outgoing;
	retire_session = retire_session;
	destroy_session = destroy_session;
};
