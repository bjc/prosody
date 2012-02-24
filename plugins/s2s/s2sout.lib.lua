-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

--- Module containing all the logic for connecting to a remote server

local t_insert = table.insert;
local t_sort = table.sort;
local ipairs = ipairs;

local wrapclient = require "net.server".wrapclient;
local initialize_filters = require "util.filters".initialize;
local idna_to_ascii = require "util.encodings".idna.to_ascii;
local add_task = require "util.timer".add_task;
local st = require "util.stanza";
local new_ip = require "util.ip".new_ip;
local rfc3484_dest = require "util.rfc3484".destination;
local socket = require "socket";

local s2s_new_outgoing = require "core.s2smanager".new_outgoing;
local s2s_destroy_session = require "core.s2smanager".destroy_session;

local cfg_sources = config.get("*", "core", "s2s_interfaces") or socket.local_addresses();

local s2sout = {};

local s2s_listener;

function s2sout.set_listener(listener)
	s2s_listener = listener;
end

local function compare_srv_priorities(a,b)
	return a.priority < b.priority or (a.priority == b.priority and a.weight > b.weight);
end

local function session_open_stream(session, from, to)
	session.sends2s(st.stanza("stream:stream", {
		xmlns='jabber:server', ["xmlns:db"]='jabber:server:dialback',
		["xmlns:stream"]='http://etherx.jabber.org/streams',
		from=from, to=to, version='1.0', ["xml:lang"]='en'}):top_tag());
end

function s2sout.initiate_connection(host_session)
	initialize_filters(host_session);
	host_session.open_stream = session_open_stream;
	
	-- Kick the connection attempting machine into life
	if not s2sout.attempt_connection(host_session) then
		-- Intentionally not returning here, the
		-- session is needed, connected or not
		s2s_destroy_session(host_session);
	end
	
	if not host_session.sends2s then
		-- A sends2s which buffers data (until the stream is opened)
		-- note that data in this buffer will be sent before the stream is authed
		-- and will not be ack'd in any way, successful or otherwise
		local buffer;
		function host_session.sends2s(data)
			if not buffer then
				buffer = {};
				host_session.send_buffer = buffer;
			end
			log("debug", "Buffering data on unconnected s2sout to %s", to_host);
			buffer[#buffer+1] = data;
			log("debug", "Buffered item %d: %s", #buffer, tostring(data));
		end
	end
end

function s2sout.attempt_connection(host_session, err)
	local from_host, to_host = host_session.from_host, host_session.to_host;
	local connect_host, connect_port = to_host and idna_to_ascii(to_host), 5269;
	
	if not connect_host then
		return false;
	end
	
	if not err then -- This is our first attempt
		log("debug", "First attempt to connect to %s, starting with SRV lookup...", to_host);
		host_session.connecting = true;
		local handle;
		handle = adns.lookup(function (answer)
			handle = nil;
			host_session.connecting = nil;
			if answer then
				log("debug", to_host.." has SRV records, handling...");
				local srv_hosts = {};
				host_session.srv_hosts = srv_hosts;
				for _, record in ipairs(answer) do
					t_insert(srv_hosts, record.srv);
				end
				if #srv_hosts == 1 and srv_hosts[1].target == "." then
					log("debug", to_host.." does not provide a XMPP service");
					s2s_destroy_session(host_session, err); -- Nothing to see here
					return;
				end
				t_sort(srv_hosts, compare_srv_priorities);
				
				local srv_choice = srv_hosts[1];
				host_session.srv_choice = 1;
				if srv_choice then
					connect_host, connect_port = srv_choice.target or to_host, srv_choice.port or connect_port;
					log("debug", "Best record found, will connect to %s:%d", connect_host, connect_port);
				end
			else
				log("debug", to_host.." has no SRV records, falling back to A");
			end
			-- Try with SRV, or just the plain hostname if no SRV
			local ok, err = s2sout.try_connect(host_session, connect_host, connect_port);
			if not ok then
				if not s2sout.attempt_connection(host_session, err) then
					-- No more attempts will be made
					s2s_destroy_session(host_session, err);
				end
			end
		end, "_xmpp-server._tcp."..connect_host..".", "SRV");
		
		return true; -- Attempt in progress
	elseif host_session.ip_hosts then
		return s2sout.try_connect(host_session, connect_host, connect_port, err);
	elseif host_session.srv_hosts and #host_session.srv_hosts > host_session.srv_choice then -- Not our first attempt, and we also have SRV
		host_session.srv_choice = host_session.srv_choice + 1;
		local srv_choice = host_session.srv_hosts[host_session.srv_choice];
		connect_host, connect_port = srv_choice.target or to_host, srv_choice.port or connect_port;
		host_session.log("info", "Connection failed (%s). Attempt #%d: This time to %s:%d", tostring(err), host_session.srv_choice, connect_host, connect_port);
	else
		host_session.log("info", "Out of connection options, can't connect to %s", tostring(host_session.to_host));
		-- We're out of options
		return false;
	end
	
	if not (connect_host and connect_port) then
		-- Likely we couldn't resolve DNS
		log("warn", "Hmm, we're without a host (%s) and port (%s) to connect to for %s, giving up :(", tostring(connect_host), tostring(connect_port), tostring(to_host));
		return false;
	end

	return s2sout.try_connect(host_session, connect_host, connect_port);
end

function s2sout.try_next_ip(host_session)
	host_session.connecting = nil;
	host_session.ip_choice = host_session.ip_choice + 1;
	local ip = host_session.ip_hosts[host_session.ip_choice];
	local ok, err= s2sout.make_connect(host_session, ip.ip, ip.port);
	if not ok then
		if not s2sout.attempt_connection(host_session, err or "closed") then
			err = err and (": "..err) or "";
			s2s_destroy_session(host_session, "Connection failed"..err);
		end
	end
end

function s2sout.try_connect(host_session, connect_host, connect_port, err)
	local sources;
	host_session.connecting = true;

	if not err then
		local IPs = {};
		host_session.ip_hosts = IPs;
		local handle4, handle6;
		local has_other = false;

		if not sources then
			sources = {};
			for i, source in ipairs(cfg_sources) do
				if source == "*" then
					sources[i] = new_ip("0.0.0.0", "IPv4");
				else
					sources[i] = new_ip(source, (source:find(":") and "IPv6") or "IPv4");
				end
			end
		end

		handle4 = adns.lookup(function (reply, err)
			handle4 = nil;

			-- COMPAT: This is a compromise for all you CNAME-(ab)users :)
			if not (reply and reply[#reply] and reply[#reply].a) then
				local count = max_dns_depth;
				reply = dns.peek(connect_host, "CNAME", "IN");
				while count > 0 and reply and reply[#reply] and not reply[#reply].a and reply[#reply].cname do
					log("debug", "Looking up %s (DNS depth is %d)", tostring(reply[#reply].cname), count);
					reply = dns.peek(reply[#reply].cname, "A", "IN") or dns.peek(reply[#reply].cname, "CNAME", "IN");
					count = count - 1;
				end
			end
			-- end of CNAME resolving

			if reply and reply[#reply] and reply[#reply].a then
				for _, ip in ipairs(reply) do
					log("debug", "DNS reply for %s gives us %s", connect_host, ip.a);
					IPs[#IPs+1] = new_ip(ip.a, "IPv4");
				end
			end

			if has_other then
				if #IPs > 0 then
					rfc3484_dest(host_session.ip_hosts, sources);
					for i = 1, #IPs do
						IPs[i] = {ip = IPs[i], port = connect_port};
					end
					host_session.ip_choice = 0;
					s2sout.try_next_ip(host_session);
				else
					log("debug", "DNS lookup failed to get a response for %s", connect_host);
					host_session.ip_hosts = nil;
					if not s2sout.attempt_connection(host_session, "name resolution failed") then -- Retry if we can
						log("debug", "No other records to try for %s - destroying", host_session.to_host);
						err = err and (": "..err) or "";
						s2s_destroy_session(host_session, "DNS resolution failed"..err); -- End of the line, we can't
					end
				end
			else
				has_other = true;
			end
		end, connect_host, "A", "IN");

		handle6 = adns.lookup(function (reply, err)
			handle6 = nil;

			if reply and reply[#reply] and reply[#reply].aaaa then
				for _, ip in ipairs(reply) do
					log("debug", "DNS reply for %s gives us %s", connect_host, ip.aaaa);
					IPs[#IPs+1] = new_ip(ip.aaaa, "IPv6");
				end
			end

			if has_other then
				if #IPs > 0 then
					rfc3484_dest(host_session.ip_hosts, sources);
					for i = 1, #IPs do
						IPs[i] = {ip = IPs[i], port = connect_port};
					end
					host_session.ip_choice = 0;
					s2sout.try_next_ip(host_session);
				else
					log("debug", "DNS lookup failed to get a response for %s", connect_host);
					host_session.ip_hosts = nil;
					if not s2sout.attempt_connection(host_session, "name resolution failed") then -- Retry if we can
						log("debug", "No other records to try for %s - destroying", host_session.to_host);
						err = err and (": "..err) or "";
						s2s_destroy_session(host_session, "DNS resolution failed"..err); -- End of the line, we can't
					end
				end
			else
				has_other = true;
			end
		end, connect_host, "AAAA", "IN");

		return true;
	elseif host_session.ip_hosts and #host_session.ip_hosts > host_session.ip_choice then -- Not our first attempt, and we also have IPs left to try
		s2sout.try_next_ip(host_session);
	else
		host_session.ip_hosts = nil;
		if not s2sout.attempt_connection(host_session, "out of IP addresses") then -- Retry if we can
			log("debug", "No other records to try for %s - destroying", host_session.to_host);
			err = err and (": "..err) or "";
			s2s_destroy_session(host_session, "Connecting failed"..err); -- End of the line, we can't
			return false;
		end
	end

	return true;
end

function s2sout.make_connect(host_session, connect_host, connect_port)
	(host_session.log or log)("info", "Beginning new connection attempt to %s ([%s]:%d)", host_session.to_host, connect_host.addr, connect_port);
	-- Ok, we're going to try to connect
	
	local from_host, to_host = host_session.from_host, host_session.to_host;
	
	local conn, handler;
	if connect_host.proto == "IPv4" then
		conn, handler = socket.tcp();
	else
		conn, handler = socket.tcp6();
	end
	
	if not conn then
		log("warn", "Failed to create outgoing connection, system error: %s", handler);
		return false, handler;
	end

	conn:settimeout(0);
	local success, err = conn:connect(connect_host.addr, connect_port);
	if not success and err ~= "timeout" then
		log("warn", "s2s connect() to %s (%s:%d) failed: %s", host_session.to_host, connect_host.addr, connect_port, err);
		return false, err;
	end
	
	conn = wrapclient(conn, connect_host.addr, connect_port, s2s_listener, "*a");
	host_session.conn = conn;
	
	local filter = initialize_filters(host_session);
	local w, log = conn.write, host_session.log;
	host_session.sends2s = function (t)
		log("debug", "sending: %s", (t.top_tag and t:top_tag()) or t:match("^[^>]*>?"));
		if t.name then
			t = filter("stanzas/out", t);
		end
		if t then
			t = filter("bytes/out", tostring(t));
			if t then
				return w(conn, tostring(t));
			end
		end
	end
	
	-- Register this outgoing connection so that xmppserver_listener knows about it
	-- otherwise it will assume it is a new incoming connection
	s2s_listener.register_outgoing(conn, host_session);
	
	host_session:open_stream(from_host, to_host);
	
	log("debug", "Connection attempt in progress...");
	return true;
end

return s2sout;
