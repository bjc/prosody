-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

--local sessions = module:shared("sessions");

--[[function listener.associate_session(conn, session)
	sessions[conn] = session;
end]]

local handlers;

function build_handlers()
	handlers = {};
	for _, item in ipairs(module:get_host_items("http-handler")) do
		local previous = handlers[item.path];
		if not previous and item.path then
			handlers[item.path] = item;
		end
	end
end
function clear_handlers()
	handlers = nil;
end
module:handle_items("http-handler", clear_handlers, clear_handlers, false);

function http_handler(event)
	local request, response = event.request, event.response;

	if not handlers then build_handlers(); end
	local item = handlers[request.path:match("[^?]*")];
	local handler = item and item.handler;
	if handler then
		handler(request, response);
		return true;
	end
end

local server = require "net.http.server";
local listener = server.listener;
server.add_handler("*", http_handler);
function module.unload()
	server.remove_handler("*", http_handler);
end
--require "net.http.server".listen_on(8080);

module:add_item("net-provider", {
	name = "http";
	listener = listener;
	default_port = 5280;
	multiplex = {
		pattern = "^[A-Z]";
	};
});

module:add_item("net-provider", {
	name = "https";
	listener = listener;
	encryption = "ssl";
	multiplex = {
		pattern = "^[A-Z]";
	};
});
