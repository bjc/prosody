local server = require "net.server";
local log = require "util.logger".init("net.connect");
local new_id = require "util.id".short;

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
		p:log("debug", "Next target to try is %s:%d", ip, port);
		local conn = assert(server.addclient(ip, port, pending_connection_listeners, p.options.pattern, p.options.sslctx, conn_type, extra));
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
	if p.listeners.onattach then
		p.listeners.onattach(conn, p.data);
	end
	conn:setlistener(p.listeners);
	return p.listeners.onconnect(conn);
end

function pending_connection_listeners.ondisconnect(conn, reason)
	local p = pending_connections_map[conn];
	if not p then
		log("warn", "Failed connection, but unexpected!");
		return;
	end
	p:log("debug", "Connection attempt failed");
	attempt_connection(p);
end

local function connect(target_resolver, listeners, options, data)
	local p = setmetatable({
		id = new_id();
		target_resolver = target_resolver;
		listeners = assert(listeners);
		options = options or {};
		cb = cb;
	}, pending_connection_mt);

	p:log("debug", "Starting connection process");
	attempt_connection(p);
end

return {
	connect = connect;
};
