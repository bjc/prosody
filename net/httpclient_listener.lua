local log = require "util.logger".init("httpclient_listener");

local connlisteners_register = require "net.connlisteners".register;

local requests = {}; -- Open requests
local buffers = {}; -- Buffers of partial lines

local httpclient = { default_port = 80, default_mode = "*a" };

function httpclient.listener(conn, data)
	local request = requests[conn];

	if not request then
		log("warn", "Received response from connection %s with no request attached!", tostring(conn));
		return;
	end

	if data and request.reader then
		request:reader(data);
	end
end

function httpclient.disconnect(conn, err)
	local request = requests[conn];
	if request then
		request:reader(nil);
	end
	requests[conn] = nil;
end

function httpclient.register_request(conn, req)
	log("debug", "Attaching request %s to connection %s", tostring(req.id or req), tostring(conn));
	requests[conn] = req;
end

connlisteners_register("httpclient", httpclient);
