-- Prosody IM
-- Copyright (C) 2008-2012 Matthew Wild
-- Copyright (C) 2008-2012 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();
module:depends("http_errors");

local portmanager = require "core.portmanager";
local moduleapi = require "core.moduleapi";
local url_parse = require "socket.url".parse;
local url_build = require "socket.url".build;
local normalize_path = require "util.http".normalize_path;
local set = require "util.set";

local server = require "net.http.server";

server.set_default_host(module:get_option_string("http_default_host"));

server.set_option("body_size_limit", module:get_option_number("http_max_content_size"));
server.set_option("buffer_size_limit", module:get_option_number("http_max_buffer_size"));

-- CORS settigs
local opt_methods = module:get_option_set("access_control_allow_methods", { "GET", "OPTIONS" });
local opt_headers = module:get_option_set("access_control_allow_headers", { "Content-Type" });
local opt_credentials = module:get_option_boolean("access_control_allow_credentials", false);
local opt_max_age = module:get_option_number("access_control_max_age", 2 * 60 * 60);

local function get_http_event(host, app_path, key)
	local method, path = key:match("^(%S+)%s+(.+)$");
	if not method then -- No path specified, default to "" (base path)
		method, path = key, "";
	end
	if method:sub(1,1) == "/" then
		return nil;
	end
	if app_path == "/" and path:sub(1,1) == "/" then
		app_path = "";
	end
	if host == "*" then
		return method:upper().." "..app_path..path;
	else
		return method:upper().." "..host..app_path..path;
	end
end

local function get_base_path(host_module, app_name, default_app_path)
	return (normalize_path(host_module:get_option("http_paths", {})[app_name] -- Host
		or module:get_option("http_paths", {})[app_name] -- Global
		or default_app_path)) -- Default
		:gsub("%$(%w+)", { host = host_module.host });
end

local function redir_handler(event)
	event.response.headers.location = event.request.path.."/";
	if event.request.url.query then
		event.response.headers.location = event.response.headers.location .. "?" .. event.request.url.query
	end
	return 301;
end

local ports_by_scheme = { http = 80, https = 443, };

-- Helper to deduce a module's external URL
function moduleapi.http_url(module, app_name, default_path)
	app_name = app_name or (module.name:gsub("^http_", ""));
	local external_url = url_parse(module:get_option_string("http_external_url")) or {};
	if external_url.scheme and external_url.port == nil then
		external_url.port = ports_by_scheme[external_url.scheme];
	end
	local services = portmanager.get_active_services();
	local http_services = services:get("https") or services:get("http") or {};
	for interface, ports in pairs(http_services) do -- luacheck: ignore 213/interface
		for port, service in pairs(ports) do -- luacheck: ignore 512
			local url = {
				scheme = (external_url.scheme or service[1].service.name);
				host = (external_url.host or module:get_option_string("http_host", module.host));
				port = tonumber(external_url.port) or port or 80;
				path = normalize_path(external_url.path or "/", true)..
					(get_base_path(module, app_name, default_path or "/"..app_name):sub(2));
			}
			if ports_by_scheme[url.scheme] == url.port then url.port = nil end
			return url_build(url);
		end
	end
	module:log("warn", "No http ports enabled, can't generate an external URL");
	return "http://disabled.invalid/";
end

local function apply_cors_headers(response, methods, headers, max_age, allow_credentials, origin)
	response.headers.access_control_allow_methods = tostring(methods);
	response.headers.access_control_allow_headers = tostring(headers);
	response.headers.access_control_max_age = tostring(max_age)
	response.headers.access_control_allow_origin = origin or "*";
	if allow_credentials then
		response.headers.access_control_allow_credentials = "true";
	end
end

function module.add_host(module)
	local host = module.host;
	if host ~= "*" then
		host = module:get_option_string("http_host", host);
	end
	local apps = {};
	module.environment.apps = apps;
	local function http_app_added(event)
		local app_name = event.item.name;
		local default_app_path = event.item.default_path or "/"..app_name;
		local app_path = get_base_path(module, app_name, default_app_path);
		if not app_name then
			-- TODO: Link to docs
			module:log("error", "HTTP app has no 'name', add one or use module:provides('http', app)");
			return;
		end
		apps[app_name] = apps[app_name] or {};
		local app_handlers = apps[app_name];

		local app_methods = opt_methods;

		local function cors_handler(event_data)
			local request, response = event_data.request, event_data.response;
			apply_cors_headers(response, app_methods, opt_headers, opt_max_age, opt_credentials, request.headers.origin);
		end

		local function options_handler(event_data)
			cors_handler(event_data);
			return "";
		end

		for key, handler in pairs(event.item.route or {}) do
			local event_name = get_http_event(host, app_path, key);
			if event_name then
				local method = event_name:match("^%S+");
				if not app_methods:contains(method) then
					app_methods = app_methods + set.new{ method };
				end
				local options_event_name = event_name:gsub("^%S+", "OPTIONS");
				if type(handler) ~= "function" then
					local data = handler;
					handler = function () return data; end
				elseif event_name:sub(-2, -1) == "/*" then
					local base_path_len = #event_name:match("/.+$");
					local _handler = handler;
					handler = function (_event)
						local path = _event.request.path:sub(base_path_len);
						return _handler(_event, path);
					end;
					module:hook_object_event(server, event_name:sub(1, -3), redir_handler, -1);
				elseif event_name:sub(-1, -1) == "/" then
					module:hook_object_event(server, event_name:sub(1, -2), redir_handler, -1);
				end
				if not app_handlers[event_name] then
					app_handlers[event_name] = handler;
					module:hook_object_event(server, event_name, handler);
					module:hook_object_event(server, event_name, cors_handler, 1);
					module:hook_object_event(server, options_event_name, options_handler, -1);
				else
					module:log("warn", "App %s added handler twice for '%s', ignoring", app_name, event_name);
				end
			else
				module:log("error", "Invalid route in %s, %q. See https://prosody.im/doc/developers/http#routes", app_name, key);
			end
		end
		local services = portmanager.get_active_services();
		if services:get("https") or services:get("http") then
			module:log("debug", "Serving '%s' at %s", app_name, module:http_url(app_name, app_path));
		else
			module:log("warn", "Not listening on any ports, '%s' will be unreachable", app_name);
		end
	end

	local function http_app_removed(event)
		local app_handlers = apps[event.item.name];
		apps[event.item.name] = nil;
		for event_name, handler in pairs(app_handlers) do
			module:unhook_object_event(server, event_name, handler);
		end
	end

	module:handle_items("http-provider", http_app_added, http_app_removed);

	if host ~= "*" then
		server.add_host(host);
		function module.unload()
			server.remove_host(host);
		end
	end
end

module.add_host(module); -- set up handling on global context too

local trusted_proxies = module:get_option_set("trusted_proxies", { "127.0.0.1", "::1" })._items;

local function get_ip_from_request(request)
	local ip = request.conn:ip();
	local forwarded_for = request.headers.x_forwarded_for;
	if forwarded_for then
		forwarded_for = forwarded_for..", "..ip;
		for forwarded_ip in forwarded_for:gmatch("[^%s,]+") do
			if not trusted_proxies[forwarded_ip] then
				ip = forwarded_ip;
			end
		end
	end
	return ip;
end

module:wrap_object_event(server._events, false, function (handlers, event_name, event_data)
	local request = event_data.request;
	if request then
		-- Not included in eg http-error events
		request.ip = get_ip_from_request(request);
	end
	return handlers(event_name, event_data);
end);

module:provides("net", {
	name = "http";
	listener = server.listener;
	default_port = 5280;
	multiplex = {
		pattern = "^[A-Z]";
	};
});

module:provides("net", {
	name = "https";
	listener = server.listener;
	default_port = 5281;
	encryption = "ssl";
	multiplex = {
		pattern = "^[A-Z]";
	};
});
