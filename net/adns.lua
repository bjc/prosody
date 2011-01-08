-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local server = require "net.server";
local dns = require "net.dns";

local log = require "util.logger".init("adns");

local t_insert, t_remove = table.insert, table.remove;
local coroutine, tostring, pcall = coroutine, tostring, pcall;

local function dummy_send(sock, data, i, j) return (j-i)+1; end

module "adns"

function lookup(handler, qname, qtype, qclass)
	return coroutine.wrap(function (peek)
				if peek then
					log("debug", "Records for %s already cached, using those...", qname);
					handler(peek);
					return;
				end
				log("debug", "Records for %s not in cache, sending query (%s)...", qname, tostring(coroutine.running()));
				local ok, err = dns.query(qname, qtype, qclass);
				if ok then
					coroutine.yield({ qclass or "IN", qtype or "A", qname, coroutine.running()}); -- Wait for reply
					log("debug", "Reply for %s (%s)", qname, tostring(coroutine.running()));
				end
				if ok then
					ok, err = pcall(handler, dns.peek(qname, qtype, qclass));
				else
					log("error", "Error sending DNS query: %s", err);
					ok, err = pcall(handler, nil, err);
				end
				if not ok then
					log("error", "Error in DNS response handler: %s", tostring(err));
				end
			end)(dns.peek(qname, qtype, qclass));
end

function cancel(handle, call_handler, reason)
	log("warn", "Cancelling DNS lookup for %s", tostring(handle[3]));
	dns.cancel(handle[1], handle[2], handle[3], handle[4], call_handler);
end

function new_async_socket(sock, resolver)
	local peername = "<unknown>";
	local listener = {};
	local handler = {};
	function listener.onincoming(conn, data)
		if data then
			dns.feed(handler, data);
		end
	end
	function listener.ondisconnect(conn, err)
		if err then
			log("warn", "DNS socket for %s disconnected: %s", peername, err);
			local servers = resolver.server;
			if resolver.socketset[conn] == resolver.best_server and resolver.best_server == #servers then
				log("error", "Exhausted all %d configured DNS servers, next lookup will try %s again", #servers, servers[1]);
			end
		
			resolver:servfail(conn); -- Let the magic commence
		end
	end
	handler = server.wrapclient(sock, "dns", 53, listener);
	if not handler then
		log("warn", "handler is nil");
	end
	
	handler.settimeout = function () end
	handler.setsockname = function (_, ...) return sock:setsockname(...); end
	handler.setpeername = function (_, ...) peername = (...); local ret = sock:setpeername(...); _:set_send(dummy_send); return ret; end
	handler.connect = function (_, ...) return sock:connect(...) end
	--handler.send = function (_, data) _:write(data);  return _.sendbuffer and _.sendbuffer(); end
	handler.send = function (_, data)
		local getpeername = sock.getpeername;
		log("debug", "Sending DNS query to %s", (getpeername and getpeername(sock)) or "<unconnected>");
		return sock:send(data);
	end
	return handler;
end

dns.socket_wrapper_set(new_async_socket);

return _M;
