local config = require "core.configmanager";
local certmanager = require "core.certmanager";
local server = require "net.server";

local log = require "util.logger".init("portmanager");
local multitable = require "util.multitable";
local set = require "util.set";

local table = table;
local setmetatable, rawset, rawget = setmetatable, rawset, rawget;
local type, tonumber, ipairs, pairs = type, tonumber, ipairs, pairs;

local prosody = prosody;
local fire_event = prosody.events.fire_event;

module "portmanager";

--- Config

local default_interfaces = { "*" };
local default_local_interfaces = { "127.0.0.1" };
if config.get("*", "use_ipv6") then
	table.insert(default_interfaces, "::");
	table.insert(default_local_interfaces, "::1");
end

--- Private state

-- service_name -> { service_info, ... }
local services = setmetatable({}, { __index = function (t, k) rawset(t, k, {}); return rawget(t, k); end });

-- service_name, interface (string), port (number)
local active_services = multitable.new();

--- Private helpers

local function error_to_friendly_message(service_name, port, err)
	local friendly_message = err;
	if err:match(" in use") then
		-- FIXME: Use service_name here
		if port == 5222 or port == 5223 or port == 5269 then
			friendly_message = "check that Prosody or another XMPP server is "
				.."not already running and using this port";
		elseif port == 80 or port == 81 then
			friendly_message = "check that a HTTP server is not already using "
				.."this port";
		elseif port == 5280 then
			friendly_message = "check that Prosody or a BOSH connection manager "
				.."is not already running";
		else
			friendly_message = "this port is in use by another application";
		end
	elseif err:match("permission") then
		friendly_message = "Prosody does not have sufficient privileges to use this port";
	elseif err == "no ssl context" then
		if not config.get("*", "core", "ssl") then
			friendly_message = "there is no 'ssl' config under Host \"*\" which is "
				.."require for legacy SSL ports";
		else
			friendly_message = "initializing SSL support failed, see previous log entries";
		end
	end
	return friendly_message;
end

prosody.events.add_handler("item-added/net-provider", function (event)
	local item = event.item;
	register_service(item.name, item);
end);
prosody.events.add_handler("item-removed/net-provider", function (event)
	local item = event.item;
	unregister_service(item.name, item);
end);

--- Public API

function activate(service_name)
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
		or (service_info.private and default_local_interfaces)
		or config.get("*", "interfaces")
		or config.get("*", "interface") -- COMPAT w/pre-0.9
		or listener.default_interface -- COMPAT w/pre0.9
		or default_interfaces
	bind_interfaces = set.new(type(bind_interfaces)~="table" and {bind_interfaces} or bind_interfaces);
	
	local bind_ports = set.new(config.get("*", config_prefix.."ports")
		or service_info.default_ports
		or {service_info.default_port
		    or listener.default_port -- COMPAT w/pre-0.9
		   });

	local mode, ssl = listener.default_mode or "*a";
	
	for interface in bind_interfaces do
		for port in bind_ports do
			port = tonumber(port);
			if #active_services:search(nil, interface, port) > 0 then
				log("error", "Multiple services configured to listen on the same port ([%s]:%d): %s, %s", interface, port, active_services:search(nil, interface, port)[1][1].service.name or "<unnamed>", service_name or "<unnamed>");
			else
				-- Create SSL context for this service/port
				if service_info.encryption == "ssl" then
					local ssl_config = config.get("*", config_prefix.."ssl");
					ssl = certmanager.create_context(service_info.name.." port "..port, "server", ssl_config and (ssl_config[port]
						or (ssl_config.certificate and ssl_config)));
				end
				-- Start listening on interface+port
				local handler, err = server.addserver(interface, port, listener, mode, ssl);
				if not handler then
					log("error", "Failed to open server port %d on %s, %s", port, interface, error_to_friendly_message(service_name, port, err));
				else
					log("debug", "Added listening service %s to [%s]:%d", service_name, interface, port);
					active_services:add(service_name, interface, port, {
						server = handler;
						service = service_info;
					});
				end
			end
		end
	end
	log("info", "Activated service '%s'", service_name);
	return true;
end

function deactivate(service_name)
	local active = active_services:search(service_name)[1];
	if not active then return; end
	for interface, ports in pairs(active) do
		for port, active_service in pairs(ports) do
			close(interface, port);
		end
	end
	log("info", "Deactivated service '%s'", service_name);
end

function register_service(service_name, service_info)
	table.insert(services[service_name], service_info);

	if not active_services:get(service_name) then
		log("debug", "No active service for %s, activating...", service_name);
		local ok, err = activate(service_name);
		if not ok then
			log("error", "Failed to activate service '%s': %s", service_name, err or "unknown error");
		end
	end
	
	fire_event("service-added", { name = service_name, service = service_info });
	return true;
end

function unregister_service(service_name, service_info)
	local service_info_list = services[service_name];
	for i, service in ipairs(service_info_list) do
		if service == service_info then
			table.remove(service_info_list, i);
		end
	end
	if active_services[service_name] == service_info then
		deactivate(service_name);
		if #service_info_list > 0 then -- Other services registered with this name
			activate(service_name); -- Re-activate with the next available one
		end
	end
	fire_event("service-removed", { name = service_name, service = service_info });
end

function close(interface, port)
	local service, server = get_service_at(interface, port);
	if not service then
		return false, "port-not-open";
	end
	server:close();
	active_services:remove(service.name, interface, port);
	log("debug", "Removed listening service %s from [%s]:%d", service.name, interface, port);
	return true;
end

function get_service_at(interface, port)
	local data = active_services:search(nil, interface, port)[1][1];
	return data.service, data.server;
end

function get_service(service_name)
	return services[service_name];
end

function get_active_services(...)
	return active_services;
end

function get_registered_services()
	return services;
end

return _M;
