-- Prosody IM
-- Copyright (C) 2008-2012 Matthew Wild
-- Copyright (C) 2008-2012 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();
pcall(function ()
	module:depends("http_errors");
end);

local portmanager = require "prosody.core.portmanager";
local moduleapi = require "prosody.core.moduleapi";
local url_parse = require "socket.url".parse;
local url_build = require "socket.url".build;
local http_util = require "prosody.util.http";
local normalize_path = http_util.normalize_path;
local set = require "prosody.util.set";
local array = require "prosody.util.array";

local ip_util = require "prosody.util.ip";
local new_ip = ip_util.new_ip;
local match_ip = ip_util.match;
local parse_cidr = ip_util.parse_cidr;

local server = require "prosody.net.http.server";

server.set_default_host(module:get_option_string("http_default_host"));

server.set_option("body_size_limit", module:get_option_number("http_max_content_size", nil, 0));
server.set_option("buffer_size_limit", module:get_option_number("http_max_buffer_size", nil, 0));

-- CORS settings
local cors_overrides = module:get_option("http_cors_override", {});
local opt_methods = module:get_option_set("access_control_allow_methods", { "GET", "OPTIONS" });
local opt_headers = module:get_option_set("access_control_allow_headers", { "Content-Type" });
local opt_origins = module:get_option_set("access_control_allow_origins");
local opt_credentials = module:get_option_boolean("access_control_allow_credentials", false);
local opt_max_age = module:get_option_period("access_control_max_age", "2 hours");
local opt_default_cors = module:get_option_boolean("http_default_cors_enabled", true);

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
function moduleapi.http_url(module, app_name, default_path, mode)
	app_name = app_name or (module.name:gsub("^http_", ""));

	local external_url = url_parse(module:get_option_string("http_external_url"));
	if external_url and mode ~= "internal" then
		-- Current URL does not depend on knowing which ports are used, only configuration.
		local url = {
			scheme = external_url.scheme;
			host = external_url.host;
			port = tonumber(external_url.port) or ports_by_scheme[external_url.scheme];
			path = normalize_path(external_url.path or "/", true)
				.. (get_base_path(module, app_name, default_path or "/" .. app_name):sub(2));
		}
		if ports_by_scheme[url.scheme] == url.port then url.port = nil end
		return url_build(url);
	end

	if prosody.process_type ~= "prosody" then
		-- We generally don't open ports outside of Prosody, so we can't rely on
		-- portmanager to tell us which ports and services are used and derive the
		-- URL from that, so instead we derive it entirely from configuration.
		local https_ports = module:get_option_array("https_ports", { 5281 });
		local scheme = "https";
		local port = tonumber(https_ports[1]);
		if not port then
			-- https is disabled and no http_external_url set
			scheme = "http";
			local http_ports = module:get_option_array("http_ports", { 5280 });
			port = tonumber(http_ports[1]);
			if not port then
				return "http://disabled.invalid/";
			end
		end

		local url = {
			scheme = scheme;
			host = module:get_option_string("http_host", module.global and module:get_option_string("http_default_host") or module.host);
			port = port;
			path = get_base_path(module, app_name, default_path or "/" .. app_name);
		}
		if ports_by_scheme[url.scheme] == url.port then
			url.port = nil
		end
		return url_build(url);
	end

	-- Use portmanager to find the actual port of https or http services
	local services = portmanager.get_active_services();
	local http_services = services:get("https") or services:get("http") or {};
	for interface, ports in pairs(http_services) do -- luacheck: ignore 213/interface
		for port, service in pairs(ports) do -- luacheck: ignore 512
			local url = {
				scheme = service[1].service.name;
				host = module:get_option_string("http_host", module.global
					and module:get_option_string("http_default_host", interface) or module.host);
				port = port;
				path = get_base_path(module, app_name, default_path or "/" .. app_name);
			}
			if ports_by_scheme[url.scheme] == url.port then url.port = nil end
			return url_build(url);
		end
	end
	if prosody.process_type == "prosody" then
		module:log("warn", "No http ports enabled, can't generate an external URL");
	end
	return "http://disabled.invalid/";
end

local function header_set_tostring(header_value)
	return array(header_value:items()):concat(", ");
end

local function apply_cors_headers(response, methods, headers, max_age, allow_credentials, allowed_origins, origin)
	if allowed_origins and not allowed_origins[origin] then
		return;
	end
	response.headers.access_control_allow_methods = header_set_tostring(methods);
	response.headers.access_control_allow_headers = header_set_tostring(headers);
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
		local app_headers = opt_headers;
		local app_credentials = opt_credentials;
		local app_origins;
		if opt_origins and not (opt_origins:empty() or opt_origins:contains("*")) then
			app_origins = opt_origins._items;
		end

		local function cors_handler(event_data)
			local request, response = event_data.request, event_data.response;
			apply_cors_headers(response, app_methods, app_headers, opt_max_age, app_credentials, app_origins, request.headers.origin);
		end

		local function options_handler(event_data)
			cors_handler(event_data);
			return "";
		end

		local cors = cors_overrides[app_name] or event.item.cors;
		if cors then
			if cors.enabled == true then
				if cors.credentials ~= nil then
					app_credentials = cors.credentials;
				end
				if cors.headers then
					for header, enable in pairs(cors.headers) do
						if enable and not app_headers:contains(header) then
							app_headers = app_headers + set.new { header };
						elseif not enable and app_headers:contains(header) then
							app_headers = app_headers - set.new { header };
						end
					end
				end
				if cors.origins then
					if cors.origins == "*" or cors.origins[1] == "*" then
						app_origins = nil;
					else
						app_origins = set.new(cors.origins)._items;
					end
				end
			elseif cors.enabled == false then
				cors = nil;
			end
		else
			cors = opt_default_cors;
		end

		local streaming = event.item.streaming_uploads;

		if not event.item.route then
			-- TODO: Link to docs
			module:log("error", "HTTP app %q provides no 'route', add one to handle HTTP requests", app_name);
			return;
		end

		for key, handler in pairs(event.item.route) do
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
				if not streaming then
					-- COMPAT Modules not compatible with streaming uploads behave as before.
					local _handler = handler;
					function handler(event) -- luacheck: ignore 432/event
						if event.request.body ~= false then
							return _handler(event);
						end
					end
				end
				if not app_handlers[event_name] then
					app_handlers[event_name] = {
						main = handler;
						cors = cors and cors_handler;
						options = cors and options_handler;
					};
					module:hook_object_event(server, event_name, handler);
					if cors then
						module:hook_object_event(server, event_name, cors_handler, 1);
						module:hook_object_event(server, options_event_name, options_handler, -1);
					end
				else
					module:log("warn", "App %s added handler twice for '%s', ignoring", app_name, event_name);
				end
			else
				module:log("error", "Invalid route in %s, %q. See https://prosody.im/doc/developers/http#routes", app_name, key);
			end
		end
		local services = portmanager.get_active_services();
		if services:get("https") or services:get("http") then
			module:log("info", "Serving '%s' at %s", app_name, module:http_url(app_name, app_path));
		elseif prosody.process_type == "prosody" then
			module:log("error", "Not listening on any ports, '%s' will be unreachable", app_name);
		end
	end

	local function http_app_removed(event)
		local app_handlers = apps[event.item.name];
		apps[event.item.name] = nil;
		for event_name, handlers in pairs(app_handlers) do
			module:unhook_object_event(server, event_name, handlers.main);
			if handlers.cors then
				module:unhook_object_event(server, event_name, handlers.cors);
			end

			if event_name:sub(-2, -1) == "/*" then
				module:unhook_object_event(server, event_name:sub(1, -3), redir_handler, -1);
			elseif event_name:sub(-1, -1) == "/" then
				module:unhook_object_event(server, event_name:sub(1, -2), redir_handler, -1);
			end

			if handlers.options then
				local options_event_name = event_name:gsub("^%S+", "OPTIONS");
				module:unhook_object_event(server, options_event_name, handlers.options);
			end
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

--- deal with [ipv6]:port / ip:port format
local function normal_ip(ip)
	return ip:match("^%[([%x:]*)%]") or ip:match("^%d+%.%d+%.%d+%.%d+") or ip;
end

local function is_trusted_proxy(ip)
	ip = normal_ip(ip);
	if trusted_proxies[ip] then
		return true;
	end
	local parsed_ip, err = new_ip(ip);
	if not parsed_ip then return nil, err; end
	for trusted_proxy in trusted_proxies do
		if match_ip(parsed_ip, parse_cidr(trusted_proxy)) then
			return true;
		end
	end
	return false
end

local function get_forwarded_connection_info(request) --> ip:string, secure:boolean
	local ip = request.ip;
	local secure = request.secure; -- set by net.http.server

	local forwarded = http_util.parse_forwarded(request.headers.forwarded);
	if forwarded then
		request.forwarded = forwarded;
		for i = #forwarded, 1, -1 do
			local proxy = forwarded[i]
			local trusted, err = is_trusted_proxy(ip);
			if trusted then
				ip = normal_ip(proxy["for"]);
				secure = secure and proxy.proto == "https";
			else
				if err then
					request.log("warn", "Could not parse forwarded connection details: %s");
				end
				break
			end
		end
	end

	return ip, secure;
end

-- TODO switch to RFC 7239 by default once support is more common
if module:get_option_boolean("http_legacy_x_forwarded", true) then
function get_forwarded_connection_info(request) --> ip:string, secure:boolean
	local ip = request.ip;
	local secure = request.secure; -- set by net.http.server

	local forwarded_for = request.headers.x_forwarded_for;
	if forwarded_for then
		-- luacheck: ignore 631
		-- This logic looks weird at first, but it makes sense.
		-- The for loop will take the last non-trusted-proxy IP from `forwarded_for`.
		-- We append the original request IP to the header. Then, since the last IP wins, there are two cases:
		-- Case a) The original request IP is *not* in trusted proxies, in which case the X-Forwarded-For header will, effectively, be ineffective; the original request IP will win because it overrides any other IP in the header.
		-- Case b) The original request IP is in trusted proxies. In that case, the if branch in the for loop will skip the last IP, causing it to be ignored. The second-to-last IP will be taken instead.
		-- Case c) If the second-to-last IP is also a trusted proxy, it will also be ignored, iteratively, up to the last IP which isn’t in trusted proxies.
		-- Case d) If all IPs are in trusted proxies, something went obviously wrong and the logic never overwrites `ip`, leaving it at the original request IP.
		forwarded_for = forwarded_for..", "..ip;
		for forwarded_ip in forwarded_for:gmatch("[^%s,]+") do
			local trusted, err = is_trusted_proxy(forwarded_ip);
			if err then
				request.log("warn", "Could not parse forwarded connection details: %s");
			elseif not trusted then
				ip = forwarded_ip;
			end
		end
	end

	secure = secure or request.headers.x_forwarded_proto == "https";

	return ip, secure;
end
end

module:wrap_object_event(server._events, false, function (handlers, event_name, event_data)
	local request = event_data.request;
	if request and is_trusted_proxy(request.ip) then
		-- Not included in eg http-error events
		request.ip, request.secure = get_forwarded_connection_info(request);
	end
	return handlers(event_name, event_data);
end);

module:provides("net", {
	name = "http";
	listener = server.listener;
	private = true;
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
		protocol = "http/1.1";
		pattern = "^[A-Z]";
	};
});
