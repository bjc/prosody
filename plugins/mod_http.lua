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

local NULL = {};
local handlers = {};

function build_handlers(host)
	if not hosts[host] then return; end
	local h = {};
	handlers[host] = h;
	
	for mod_name, module in pairs(modulemanager.get_modules(host)) do
		module = module.module;
		if module.items then
			for _, item in ipairs(module.items["http-handler"] or NULL) do
				local previous = handlers[item.path];
				if not previous and item.path then
					h[item.path] = item;
				end
			end
		end
	end

	return h;
end
function clear_handlers(event)
	handlers[event.source.host] = nil;
end
function get_handler(host, path)
	local h = handlers[host] or build_handlers(host);
	if h then
		local item = h[path];
		return item and item.handler;
	end
end
module:handle_items("http-handler", clear_handlers, clear_handlers, false);

function http_handler(event)
	local request, response = event.request, event.response;

	local handler = get_handler(request.headers.host:match("[^:]*"):lower(), request.path:match("[^?]*"));
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
