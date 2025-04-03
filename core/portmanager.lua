local config = require "prosody.core.configmanager";
local certmanager = require "prosody.core.certmanager";
local server = require "prosody.net.server";
local socket = require "socket";

local log = require "prosody.util.logger".init("portmanager");
local multitable = require "prosody.util.multitable";
local set = require "prosody.util.set";

local table = table;
local setmetatable, rawset, rawget = setmetatable, rawset, rawget;
local type, tonumber, ipairs = type, tonumber, ipairs;
local pairs = pairs;

local prosody = prosody;
local fire_event = prosody.events.fire_event;

local _ENV = nil;
-- luacheck: std none

--- Config

local default_interfaces = { };
local default_local_interfaces = { };
if config.get("*", "use_ipv4") ~= false then
	table.insert(default_interfaces, "*");
	table.insert(default_local_interfaces, "127.0.0.1");
end
if socket.tcp6 and config.get("*", "use_ipv6") ~= false then
	table.insert(default_interfaces, "::");
	table.insert(default_local_interfaces, "::1");
end

local default_mode = config.get("*", "network_default_read_size") or 4096;

--- Private state

-- service_name -> { service_info, ... }
local services = setmetatable({}, { __index = function (t, k) rawset(t, k, {}); return rawget(t, k); end });

-- service_name, interface (string), port (number)
local active_services = multitable.new();

--- Private helpers

local function error_to_friendly_message(service_name, port, err) --luacheck: ignore 212/service_name
	local friendly_message = err;
	if err:match(" in use") then
		-- FIXME: Use service_name here
		if port == 5222 or port == 5223 or port == 5269 then
			friendly_message = "check that Prosody or another XMPP server is not already running and using this port";
		elseif port == 80 or port == 81 or port == 443 then
			friendly_message = "check that a HTTP server is not already using this port";
		elseif port == 5280 then
			friendly_message = "check that Prosody or a BOSH connection manager is not already running";
		else
			friendly_message = "this port is in use by another application";
		end
	elseif err:match("permission") then
		friendly_message = "Prosody does not have sufficient privileges to use this port";
	end
	return friendly_message;
end

local function get_port_ssl_ctx(port, interface, config_prefix, service_info)
	local global_ssl_config = config.get("*", "ssl") or {};
	local prefix_ssl_config = config.get("*", config_prefix.."ssl") or global_ssl_config;
	log("debug", "Creating context for direct TLS service %s on port %d", service_info.name, port);
	local ssl, err, cfg = certmanager.create_context(service_info.name.." port "..port, "server",
		prefix_ssl_config[interface],
		prefix_ssl_config[port],
		prefix_ssl_config,
		service_info.ssl_config or {},
		global_ssl_config[interface],
		global_ssl_config[port]);
	return ssl, cfg, err;
end

--- Public API

local function activate(service_name)
	local service_info = services[service_name][1];
	if not service_info then
		return nil, "Unknown service: "..service_name;
	end

	local listener = service_info.listener;

	local config_prefix = (service_info.config_prefix or service_name).."_";
	if config_prefix == "_" then
		config_prefix = "";
	end

	local bind_interfaces = config.get("*", config_prefix.."interfaces")
		or config.get("*", config_prefix.."interface") -- COMPAT w/pre-0.9
		or (service_info.private and (config.get("*", "local_interfaces") or default_local_interfaces))
		or config.get("*", "interfaces")
		or config.get("*", "interface") -- COMPAT w/pre-0.9
		or listener.default_interface -- COMPAT w/pre0.9
		or default_interfaces
	bind_interfaces = set.new(type(bind_interfaces)~="table" and {bind_interfaces} or bind_interfaces);

	local bind_ports = config.get("*", config_prefix.."ports")
		or service_info.default_ports
		or {service_info.default_port
		    or listener.default_port -- COMPAT w/pre-0.9
		   }
	bind_ports = set.new(type(bind_ports) ~= "table" and { bind_ports } or bind_ports );

	local mode = listener.default_mode or default_mode;
	local hooked_ports = {};

	for interface in bind_interfaces do
		for port in bind_ports do
			local port_number = tonumber(port);
			if not port_number then
				log("error", "Invalid port number specified for service '%s': %s", service_info.name, port);
			elseif #active_services:search(nil, interface, port_number) > 0 then
				log("error", "Multiple services configured to listen on the same port ([%s]:%d): %s, %s", interface, port,
					active_services:search(nil, interface, port)[1][1].service.name or "<unnamed>", service_name or "<unnamed>");
			else
				local ssl, cfg, err;
				-- Create SSL context for this service/port
				if service_info.encryption == "ssl" then
					ssl, cfg, err = get_port_ssl_ctx(port, interface, config_prefix, service_info);
					if not ssl then
						log("error", "Error binding encrypted port for %s: %s", service_info.name,
							error_to_friendly_message(service_name, port_number, err) or "unknown error");
					end
				end
				if not err then
					-- Start listening on interface+port
					local handler, err = server.listen(interface, port_number, listener, {
						read_size = mode,
						tls_ctx = ssl,
						tls_direct = service_info.encryption == "ssl";
						sni_hosts = {},
					});
					if not handler then
						log("error", "Failed to open server port %d on %s, %s", port_number, interface,
							error_to_friendly_message(service_name, port_number, err));
					else
						table.insert(hooked_ports, "["..interface.."]:"..port_number);
						log("debug", "Added listening service %s to [%s]:%d", service_name, interface, port_number);
						active_services:add(service_name, interface, port_number, {
							server = handler;
							service = service_info;
							tls_cfg = cfg;
						});
					end
				end
			end
		end
	end
	log("info", "Activated service '%s' on %s", service_name,
		#hooked_ports == 0 and "no ports" or table.concat(hooked_ports, ", "));
	return true;
end

local close; -- forward declaration

local function deactivate(service_name, service_info)
	for name, interface, port, n, active_service --luacheck: ignore 213/name 213/n
		in active_services:iter(service_name or service_info and service_info.name, nil, nil, nil) do
		if service_info == nil or active_service.service == service_info then
			close(interface, port);
		end
	end
	log("info", "Deactivated service '%s'", service_name or service_info.name);
end

local function register_service(service_name, service_info)
	table.insert(services[service_name], service_info);

	if not active_services:get(service_name) and prosody.process_type == "prosody" then
		log("debug", "No active service for %s, activating...", service_name);
		local ok, err = activate(service_name);
		if not ok then
			log("error", "Failed to activate service '%s': %s", service_name, err or "unknown error");
		end
	end

	fire_event("service-added", { name = service_name, service = service_info });
	return true;
end

local function unregister_service(service_name, service_info)
	log("debug", "Unregistering service: %s", service_name);
	local service_info_list = services[service_name];
	for i, service in ipairs(service_info_list) do
		if service == service_info then
			table.remove(service_info_list, i);
		end
	end
	deactivate(nil, service_info);
	if #service_info_list > 0 then -- Other services registered with this name
		activate(service_name); -- Re-activate with the next available one
	end
	fire_event("service-removed", { name = service_name, service = service_info });
end

local get_service_at -- forward declaration

function close(interface, port)
	local service, service_server = get_service_at(interface, port);
	if not service then
		return false, "port-not-open";
	end
	service_server:close();
	active_services:remove(service.name, interface, port);
	log("debug", "Removed listening service %s from [%s]:%d", service.name, interface, port);
	return true;
end

function get_service_at(interface, port)
	local data = active_services:search(nil, interface, port);
	if not data or not data[1] or not data[1][1] then return nil, "not-found"; end
	data = data[1][1];
	return data.service, data.server;
end

local function get_tls_config_at(interface, port)
	local data = active_services:search(nil, interface, port);
	if not data or not data[1] or not data[1][1] then return nil, "not-found"; end
	data = data[1][1];
	return data.tls_cfg;
end

local function get_service(service_name)
	return (services[service_name] or {})[1];
end

local function get_active_services()
	return active_services;
end

local function get_registered_services()
	return services;
end

-- Event handlers

local function add_sni_host(host, service)
	log("debug", "Gathering certificates for SNI for host %s, %s service", host, service or "default");
	for name, interface, port, n, active_service --luacheck: ignore 213
		in active_services:iter(service, nil, nil, nil) do
		if active_service.server and active_service.tls_cfg then
			local config_prefix = (active_service.config_prefix or name).."_";
			if config_prefix == "_" then config_prefix = ""; end
			local prefix_ssl_config = config.get(host, config_prefix.."ssl");
			local alternate_host = name and config.get(host, name.."_host");
			if not alternate_host and name == "https" then
				-- TODO should this be some generic thing? e.g. in the service definition
				alternate_host = config.get(host, "http_host");
			end
			local autocert = certmanager.find_host_cert(alternate_host or host);
			local ssl, err, cfg = certmanager.create_context(alternate_host or host, "server", prefix_ssl_config, autocert, active_service.tls_cfg);
			if not ssl then
				log("error", "Error creating TLS context for SNI host %s: %s", host, err);
			else
				log("debug", "Using certificate %s for %s (%s) on %s (%s)", cfg.certificate, service or name, name, alternate_host or host, host)
				local ok, err = active_service.server:sslctx():set_sni_host(
					alternate_host or host,
					cfg.certificate,
					cfg.key
					);
				if not ok then
					log("error", "Error creating TLS context for SNI host %s: %s", host, err);
				end
			end
		end
	end
end
prosody.events.add_handler("item-added/net-provider", function (event)
	local item = event.item;
	register_service(item.name, item);
	for host in pairs(prosody.hosts) do
		add_sni_host(host, item.name);
	end
end);
prosody.events.add_handler("item-removed/net-provider", function (event)
	local item = event.item;
	unregister_service(item.name, item);
end);

prosody.events.add_handler("host-activated", add_sni_host);
prosody.events.add_handler("host-deactivated", function (host)
	for name, interface, port, n, active_service --luacheck: ignore 213
		in active_services:iter(nil, nil, nil, nil) do
		if active_service.tls_cfg then
			active_service.server:sslctx():remove_sni_host(host)
		end
	end
end);

prosody.events.add_handler("config-reloaded", function ()
	for service_name, interface, port, _, active_service in active_services:iter(nil, nil, nil, nil) do
		if active_service.tls_cfg then
			local service_info = active_service.service;
			local config_prefix = (service_info.config_prefix or service_name).."_";
			if config_prefix == "_" then
				config_prefix = "";
			end
			local ssl, cfg, err = get_port_ssl_ctx(port, interface, config_prefix, service_info);
			if ssl then
				active_service.server:set_sslctx(ssl);
				active_service.tls_cfg = cfg;
			else
				log("error", "Error reloading certificate for encrypted port for %s: %s", service_info.name,
					error_to_friendly_message(service_name, port, err) or "unknown error");
			end
		end
	end
	for host in pairs(prosody.hosts) do
		add_sni_host(host, nil);
	end
end, -1);

return {
	activate = activate;
	deactivate = deactivate;
	register_service = register_service;
	unregister_service = unregister_service;
	close = close;
	get_service_at = get_service_at;
	get_tls_config_at = get_tls_config_at;
	get_service = get_service;
	get_active_services = get_active_services;
	get_registered_services = get_registered_services;
};
