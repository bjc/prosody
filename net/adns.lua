-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local server = require "net.server";
local new_resolver = require "net.dns".resolver;

local log = require "util.logger".init("adns");

local coroutine, tostring, pcall = coroutine, tostring, pcall;

local function dummy_send(sock, data, i, j) return (j-i)+1; end

local _ENV = nil;

local async_resolver_methods = {};
local async_resolver_mt = { __index = async_resolver_methods };

local query_methods = {};
local query_mt = { __index = query_methods };

local function new_async_socket(sock, resolver)
	local peername = "<unknown>";
	local listener = {};
	local handler = {};
	local err;
	function listener.onincoming(conn, data)
		if data then
			resolver:feed(handler, data);
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
	handler, err = server.wrapclient(sock, "dns", 53, listener);
	if not handler then
		return nil, err;
	end

	handler.settimeout = function () end
	handler.setsockname = function (_, ...) return sock:setsockname(...); end
	handler.setpeername = function (_, ...) peername = (...); local ret, err = sock:setpeername(...); _:set_send(dummy_send); return ret, err; end
	handler.connect = function (_, ...) return sock:connect(...) end
	--handler.send = function (_, data) _:write(data);  return _.sendbuffer and _.sendbuffer(); end
	handler.send = function (_, data)
		log("debug", "Sending DNS query to %s", peername);
		return sock:send(data);
	end
	return handler;
end

function async_resolver_methods:lookup(handler, qname, qtype, qclass)
	local resolver = self._resolver;
	return coroutine.wrap(function (peek)
				if peek then
					log("debug", "Records for %s already cached, using those...", qname);
					handler(peek);
					return;
				end
				log("debug", "Records for %s not in cache, sending query (%s)...", qname, tostring(coroutine.running()));
				local ok, err = resolver:query(qname, qtype, qclass);
				if ok then
					coroutine.yield(setmetatable({ resolver, qclass or "IN", qtype or "A", qname, coroutine.running()}, query_mt)); -- Wait for reply
					log("debug", "Reply for %s (%s)", qname, tostring(coroutine.running()));
				end
				if ok then
					ok, err = pcall(handler, resolver:peek(qname, qtype, qclass));
				else
					log("error", "Error sending DNS query: %s", err);
					ok, err = pcall(handler, nil, err);
				end
				if not ok then
					log("error", "Error in DNS response handler: %s", tostring(err));
				end
			end)(resolver:peek(qname, qtype, qclass));
end

function query_methods:cancel(call_handler, reason)
	log("warn", "Cancelling DNS lookup for %s", tostring(self[4]));
	self[1].cancel(self[2], self[3], self[4], self[5], call_handler);
end

local function new_async_resolver()
	local resolver = new_resolver();
	resolver:socket_wrapper_set(new_async_socket);
	return setmetatable({ _resolver = resolver}, async_resolver_mt);
end

return {
	lookup = function (...)
		return new_async_resolver():lookup(...);
	end;
	resolver = new_async_resolver;
	new_async_socket = new_async_socket;
};
