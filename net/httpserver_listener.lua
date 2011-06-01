-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local connlisteners_register = require "net.connlisteners".register;
local new_request = require "net.httpserver".new_request;
local request_reader = require "net.httpserver".request_reader;

local requests = {}; -- Open requests

local httpserver = { default_port = 80, default_mode = "*a" };

function httpserver.onincoming(conn, data)
	local request = requests[conn];

	if not request then
		request = new_request(conn);
		requests[conn] = request;
		
		-- If using HTTPS, request is secure
		if conn:ssl() then
			request.secure = true;
		end
	end

	if data and data ~= "" then
		request_reader(request, data);
	end
end

function httpserver.ondisconnect(conn, err)
	local request = requests[conn];
	if request and not request.destroyed then
		request.conn = nil;
		request_reader(request, nil);
	end
	requests[conn] = nil;
end

connlisteners_register("httpserver", httpserver);
