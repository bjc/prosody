
local hosts = hosts;
local sessions = sessions;
local socket = require "socket";
local format = string.format;
local t_insert = table.insert;
local tostring, pairs, ipairs, getmetatable, print, newproxy, error, tonumber
    = tostring, pairs, ipairs, getmetatable, print, newproxy, error, tonumber;

local connlisteners_get = require "net.connlisteners".get;
local wraptlsclient = require "net.server".wraptlsclient;
local modulemanager = require "core.modulemanager";

local uuid_gen = require "util.uuid".generate;

local logger_init = require "util.logger".init;

local log = logger_init("s2smanager");

local md5_hash = require "util.hashes".md5;

local dialback_secret = "This is very secret!!! Ha!";

local srvmap = { ["gmail.com"] = "talk.google.com", ["identi.ca"] = "longlance.controlezvous.ca", ["cdr.se"] = "jabber.cdr.se" };

module "s2smanager"

function connect_host(from_host, to_host)
end

function send_to_host(from_host, to_host, data)
	local host = hosts[to_host];
	if host then
		-- We have a connection to this host already
		if host.type == "s2sout_unauthed" then
			host.log("debug", "trying to send over unauthed s2sout to "..to_host..", authing it now...");
			if not host.notopen and not host.dialback_key then
				host.log("debug", "dialback had not been initiated");
				initiate_dialback(host);
			end
			
			-- Queue stanza until we are able to send it
			if host.sendq then t_insert(host.sendq, data);
			else host.sendq = { data }; end
		else
			host.log("debug", "going to send stanza to "..to_host.." from "..from_host);
			-- FIXME
			if hosts[to_host].from_host ~= from_host then log("error", "WARNING! This might, possibly, be a bug, but it might not..."); end
			hosts[to_host].sends2s(data);
			host.log("debug", "stanza sent over "..hosts[to_host].type);
		end
	else
		log("debug", "opening a new outgoing connection for this stanza");
		local host_session = new_outgoing(from_host, to_host);
		-- Store in buffer
		host_session.sendq = { data };
	end
end

function disconnect_host(host)
	
end

local open_sessions = 0;

function new_incoming(conn)
	local session = { conn = conn, type = "s2sin_unauthed", direction = "incoming" };
	if true then
		session.trace = newproxy(true);
		getmetatable(session.trace).__gc = function () open_sessions = open_sessions - 1; print("s2s session got collected, now "..open_sessions.." s2s sessions are allocated") end;
	end
	open_sessions = open_sessions + 1;
	local w = conn.write;
	session.sends2s = function (t) w(tostring(t)); end
	return session;
end

function new_outgoing(from_host, to_host)
		local host_session = { to_host = to_host, from_host = from_host, notopen = true, type = "s2sout_unauthed", direction = "outgoing" };
		hosts[to_host] = host_session;
		local cl = connlisteners_get("xmppserver");
		
		local conn, handler = socket.tcp()
		
		--FIXME: Below parameters (ports/ip) are incorrect (use SRV)
		to_host = srvmap[to_host] or to_host;
		
		conn:settimeout(0);
		local success, err = conn:connect(to_host, 5269);
		if not success then
			log("warn", "s2s connect() failed: %s", err);
		end
		
		conn = wraptlsclient(cl, conn, to_host, 5269, 0, 1, hosts[from_host].ssl_ctx );
		host_session.conn = conn;

		-- Register this outgoing connection so that xmppserver_listener knows about it
		-- otherwise it will assume it is a new incoming connection
		cl.register_outgoing(conn, host_session);

		do
			local conn_name = "s2sout"..tostring(conn):match("[a-f0-9]*$");
			host_session.log = logger_init(conn_name);
		end
		
		local w = conn.write;
		host_session.sends2s = function (t) w(tostring(t)); end
		
		conn.write(format([[<stream:stream xmlns='jabber:server' xmlns:db='jabber:server:dialback' xmlns:stream='http://etherx.jabber.org/streams' from='%s' to='%s' version='1.0'>]], from_host, to_host));
		 
		return host_session;
end

function streamopened(session, attr)
	session.log("debug", "s2s stream opened");
	local send = session.sends2s;
	
	session.version = tonumber(attr.version) or 0;
	if session.version >= 1.0 and not (attr.to and attr.from) then
		print("to: "..tostring(attr.to).." from: "..tostring(attr.from));
		--error(session.to_host.." failed to specify 'to' or 'from' hostname as per RFC");
		log("warn", (session.to_host or "(unknown)").." failed to specify 'to' or 'from' hostname as per RFC");
	end
	
	if session.direction == "incoming" then
		-- Send a reply stream header
		
		for k,v in pairs(attr) do print("", tostring(k), ":::", tostring(v)); end
		
		session.to_host = attr.to;
		session.from_host = attr.from;
	
		session.streamid = uuid_gen();
		print(session, session.from_host, "incoming s2s stream opened");
		send("<?xml version='1.0'?>");
		send(format("<stream:stream xmlns='jabber:server' xmlns:db='jabber:server:dialback' xmlns:stream='http://etherx.jabber.org/streams' id='%s' from='%s'>", session.streamid, session.to_host));
	elseif session.direction == "outgoing" then
		-- If we are just using the connection for verifying dialback keys, we won't try and auth it
		if not attr.id then error("stream response did not give us a streamid!!!"); end
		session.streamid = attr.id;
	
		if not session.dialback_verifying then
			initiate_dialback(session);
		else
			mark_connected(session);
		end
	end
	--[[
	local features = {};
	modulemanager.fire_event("stream-features-s2s", session, features);
	
	send("<stream:features>");
	
	for _, feature in ipairs(features) do
		send(tostring(feature));
	end

	send("</stream:features>");]]
	log("info", "s2s stream opened successfully");
	session.notopen = nil;
end

function initiate_dialback(session)
	-- generate dialback key
	session.dialback_key = generate_dialback(session.streamid, session.to_host, session.from_host);
	session.sends2s(format("<db:result from='%s' to='%s'>%s</db:result>", session.from_host, session.to_host, session.dialback_key));
	session.log("info", "sent dialback key on outgoing s2s stream");
end

function generate_dialback(id, to, from)
	return md5_hash(id..to..from..dialback_secret); -- FIXME: See XEP-185 and XEP-220
end

function verify_dialback(id, to, from, key)
	return key == generate_dialback(id, to, from);
end

function make_authenticated(session)
	if session.type == "s2sout_unauthed" then
		session.type = "s2sout";
	elseif session.type == "s2sin_unauthed" then
		session.type = "s2sin";
	else
		return false;
	end
	session.log("info", "connection is now authenticated");
	
	mark_connected(session);
	
	return true;
end

function mark_connected(session)
	local sendq, send = session.sendq, session.sends2s;
	
	local from, to = session.from_host, session.to_host;
	
	session.log("debug", session.direction.." s2s connection "..from.."->"..to.." is now complete");
	
	local send_to_host = send_to_host;
	function session.send(data) send_to_host(to, from, data); end
	
	
	if session.direction == "outgoing" then
		if sendq then
			session.log("debug", "sending queued stanzas across new outgoing connection to "..session.to_host);
			for i, data in ipairs(sendq) do
				send(data);
				sendq[i] = nil;
			end
			session.sendq = nil;
		end
	end
end

function destroy_session(session)
	(session.log or log)("info", "Destroying "..tostring(session.direction).." session "..tostring(session.from_host).."->"..tostring(session.to_host));
	if session.direction == "outgoing" then
		hosts[session.to_host] = nil;
	end
	session.conn = nil;
	session.disconnect = nil;
	for k in pairs(session) do
		if k ~= "trace" then
			session[k] = nil;
		end
	end
end

return _M;
