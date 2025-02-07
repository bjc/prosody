-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local server = require "prosody.net.server";
local new_resolver = require "prosody.net.dns".resolver;
local promise = require "prosody.util.promise";

local log = require "prosody.util.logger".init("adns");

log("debug", "Using legacy DNS API (missing lua-unbound?)"); -- TODO write docs about luaunbound
-- TODO Raise log level once packages are available

local coroutine, pcall = coroutine, pcall;
local setmetatable = setmetatable;

local function dummy_send(sock, data, i, j) return (j-i)+1; end -- luacheck: ignore 212

local _ENV = nil;
-- luacheck: std none

local async_resolver_methods = {};
local async_resolver_mt = { __index = async_resolver_methods };

local query_methods = {};
local query_mt = { __index = query_methods };

local function new_async_socket(sock, resolver)
	local peername = "<unknown>";
	local listener = {};
	local handler = {};
	function listener.onincoming(conn, data) -- luacheck: ignore 212/conn
		if data then
			resolver:feed(handler, data);
		end
	end
	function listener.ondisconnect(conn, err)
		if err then
			log("warn", "DNS socket for %s disconnected: %s", peername, err);
			local servers = resolver.server;
			if resolver.socketset[conn] == resolver.best_server and resolver.best_server == #servers then
				log("warn", "Exhausted all %d configured DNS servers, next lookup will try %s again", #servers, servers[1]);
			end

			resolver:servfail(conn); -- Let the magic commence
		end
	end
	do
		local err;
		handler, err = server.wrapclient(sock, "dns", 53, listener);
		if not handler then
			return nil, err;
		end
	end
	if handler.set then
		-- server_epoll: only watch for incoming data
		-- avoids sending empty packet on first 'onwritable' event
		handler:set(true, false);
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

local function measure(_qclass, _qtype)
	return measure;
end

function async_resolver_methods:lookup(handler, qname, qtype, qclass)
	local resolver = self._resolver;
	local m = measure(qclass or "IN", qtype or "A");
	return coroutine.wrap(function (peek)
				if peek then
					log("debug", "Records for %s already cached, using those...", qname);
					m();
					handler(peek);
					return;
				end
				log("debug", "Records for %s not in cache, sending query (%s)...", qname, coroutine.running());
				local ok, err = resolver:query(qname, qtype, qclass);
				if ok then
					coroutine.yield(setmetatable({ resolver, qclass or "IN", qtype or "A", qname, coroutine.running()}, query_mt)); -- Wait for reply
					log("debug", "Reply for %s (%s)", qname, coroutine.running());
				end
				if ok then
					m();
					ok, err = pcall(handler, resolver:peek(qname, qtype, qclass));
				else
					log("error", "Error sending DNS query: %s", err);
					ok, err = pcall(handler, nil, err);
				end
				if not ok then
					log("error", "Error in DNS response handler: %s", err);
				end
			end)(resolver:peek(qname, qtype, qclass));
end

function async_resolver_methods:lookup_promise(qname, qtype, qclass)
	return promise.new(function (resolve, reject)
		local function handler(answer)
			if not answer then
				return reject();
			end
			resolve(answer);
		end
		self:lookup(handler, qname, qtype, qclass);
	end);
end

function query_methods:cancel(call_handler, reason) -- luacheck: ignore 212/reason
	log("warn", "Cancelling DNS lookup for %s", self[4]);
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
	instrument = function(measure_) measure = measure_; end;
};
