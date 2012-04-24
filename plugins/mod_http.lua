-- Prosody IM
-- Copyright (C) 2008-2012 Matthew Wild
-- Copyright (C) 2008-2012 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local parse_url = require "socket.url".parse;
local server = require "net.http.server";

local function normalize_path(path)
	if path:sub(1,1) ~= "/" then path = "/"..path; end
	if path:sub(-1,-1) == "/" then path = path:sub(1, -2); end
	return path;
end

local function get_http_event(host, app_path, key)
	local method, path = key:match("^(%S+)%s+(.+)$");
	if not method then
		if key:sub(1,1) ~= "/" then
			return nil;
		end
		method, path = "GET", key;
	end
	path = normalize_path(path);
	return method:upper().." "..host..app_path..path;
end

function module.add_host(module)
	local host = module.host;
	local apps = {};
	module.environment.apps = apps;
	local function http_app_added(event)
		local app_name = event.item.name;
		local default_app_path = event.item.default_path or "/"..app_name;
		local app_path = normalize_path(module:get_option_string(app_name.."_http_path", default_app_path));
		if not app_name then		
			-- TODO: Link to docs
			module:log("error", "HTTP app has no 'name', add one or use module:provides('http', app)");
			return;
		end
		apps[app_name] = apps[app_name] or {};
		local app_handlers = apps[app_name];
		for key, handler in pairs(event.item.route or {}) do
			local event_name = get_http_event(host, app_path, key);
			if event_name then
				if event_name:sub(-2, -1) == "/*" then
					local base_path = event_name:match("/(.+)/*$");
					local _handler = handler;
					handler = function (event)
						local path = event.request.path:sub(#base_path+1);
						return _handler(event, path);
					end;
				end
				if not app_handlers[event_name] then
					app_handlers[event_name] = handler;
					server.add_handler(event_name, handler);
				else
					module:log("warn", "App %s added handler twice for '%s', ignoring", app_name, event_name);
				end
			else
				module:log("error", "Invalid route in %s: %q", app_name, key);
			end
		end
	end
	
	local function http_app_removed(event)
		local app_handlers = apps[event.item.name];
		apps[event.item.name] = nil;
		for event, handler in pairs(app_handlers) do
			server.remove_handler(event, handler);
		end
	end
	
	module:handle_items("http-provider", http_app_added, http_app_removed);
end

module:add_item("net-provider", {
	name = "http";
	listener = server.listener;
	default_port = 5280;
	multiplex = {
		pattern = "^[A-Z]";
	};
});

module:add_item("net-provider", {
	name = "https";
	listener = server.listener;
	default_port = 5281;
	encryption = "ssl";
	multiplex = {
		pattern = "^[A-Z]";
	};
});
