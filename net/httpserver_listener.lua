

local connlisteners_register = require "net.connlisteners".register;
local new_request = require "net.httpserver".new_request;
local request_reader = require "net.httpserver".request_reader;

local requests = {}; -- Open requests

local httpserver = { default_port = 80, default_mode = "*a" };

function httpserver.listener(conn, data)
	local request = requests[conn];

	if not request then
		request = new_request(conn);
		requests[conn] = request;
	end

	if data then
		request_reader(request, data);
	end
end

function httpserver.disconnect(conn, err)
	local request = requests[conn];
	if request and not request.destroyed then
		request.conn = nil;
		request_reader(request, nil);
	end
	requests[conn] = nil;
end

connlisteners_register("httpserver", httpserver);
