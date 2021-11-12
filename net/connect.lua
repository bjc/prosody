local server = require "net.server";
local log = require "util.logger".init("net.connect");
local new_id = require "util.id".short;

-- TODO #1246 Happy Eyeballs
-- FIXME RFC 6724
-- FIXME Error propagation from resolvers doesn't work
-- FIXME #1428 Reuse DNS resolver object between service and basic resolver
-- FIXME #1429 Close DNS resolver object when done

local pending_connection_methods = {};
local pending_connection_mt = {
	__name = "pending_connection";
	__index = pending_connection_methods;
	__tostring = function (p)
		return "<pending connection "..p.id.." to "..tostring(p.target_resolver.hostname)..">";
	end;
};

function pending_connection_methods:log(level, message, ...)
	log(level, "[pending connection %s] "..message, self.id, ...);
end

-- pending_connections_map[conn] = pending_connection
local pending_connections_map = {};

local pending_connection_listeners = {};

local function attempt_connection(p)
	p:log("debug", "Checking for targets...");
	if p.conn then
		pending_connections_map[p.conn] = nil;
		p.conn = nil;
	end
	p.target_resolver:next(function (conn_type, ip, port, extra)
		if not conn_type then
			-- No more targets to try
			p:log("debug", "No more connection targets to try", p.target_resolver.last_error);
			if p.listeners.onfail then
				p.listeners.onfail(p.data, p.target_resolver.last_error or p.last_error or "unable to resolve service");
			end
			return;
		end
		p:log("debug", "Next target to try is %s:%d", ip, port);
		local conn, err = server.addclient(ip, port, pending_connection_listeners, p.options.pattern or "*a", p.options.sslctx, conn_type, extra);
		if not conn then
			log("debug", "Connection attempt failed immediately: %s", err);
			p.last_error = err or "unknown reason";
			return attempt_connection(p);
		end
		p.conn = conn;
		pending_connections_map[conn] = p;
	end);
end

function pending_connection_listeners.onconnect(conn)
	local p = pending_connections_map[conn];
	if not p then
		log("warn", "Successful connection, but unexpected! Closing.");
		conn:close();
		return;
	end
	pending_connections_map[conn] = nil;
	p:log("debug", "Successfully connected");
	conn:setlistener(p.listeners, p.data);
	return p.listeners.onconnect(conn);
end

function pending_connection_listeners.ondisconnect(conn, reason)
	local p = pending_connections_map[conn];
	if not p then
		log("warn", "Failed connection, but unexpected!");
		return;
	end
	p.last_error = reason or "unknown reason";
	p:log("debug", "Connection attempt failed: %s", p.last_error);
	attempt_connection(p);
end

local function connect(target_resolver, listeners, options, data)
	local p = setmetatable({
		id = new_id();
		target_resolver = target_resolver;
		listeners = assert(listeners);
		options = options or {};
		data = data;
	}, pending_connection_mt);

	p:log("debug", "Starting connection process");
	attempt_connection(p);
end

return {
	connect = connect;
};
