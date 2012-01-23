
local multitable = require "util.multitable";
local fire_event = prosody.events.fire_event;

--- Config

local default_interfaces = { "*" };
local default_local_interfaces = { "127.0.0.1" };
if config.get("*", "use_ipv6") then
	table.insert(default_interfaces, "::");
	table.insert(default_local_interfaces, "::1");
end

--- Private state

-- service_name -> service_info
local services = {};

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

module("portmanager", package.seeall);

--- Public API

function activate_service(service_name)
	local service_info = services[service_name];
	if not service_info then
		return nil, "Unknown service: "..service_name;
	end

	local bind_interfaces = set.new(config.get("*", service_name.."_interfaces")
		or config.get("*", service_name.."_interface") -- COMPAT w/pre-0.9
		or config.get("*", "interfaces")
		or config.get("*", "interface") -- COMPAT w/pre-0.9
		or (service_info.private and default_local_interfaces)
		or service_info.default_interface -- COMPAT w/pre0.9
		or default_interfaces);
	
	local bind_ports = set.new(config.get("*", service_name.."_ports")
		or (service_info.multiplex and config.get("*", "ports"))
		or service_info.default_ports
		or {service_info.default_port});

	local listener = service_info.listener;
	local mode = listener.default_mode or "*a";
	local ssl;
	if service_info.encryption == "ssl" then
		ssl = prosody.global_ssl_ctx;
		if not ssl then
			return nil, "global-ssl-context-required";
		end
	end
	
	for interface in bind_interfaces do
		for port in bind_ports do
			if not service_info.multiplex and #active_services:search(nil, interface, port) > 0 then
				log("error", "Multiple services configured to listen on the same port: %s, %s", table.concat(active_services:search(nil, interface, port), ", "), service_name);
			else
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
end

function deactivate(service_name)
	local active = active_services:search(service_name)[1];
	if not active then return; end
	for interface, ports in pairs(active) do
		for port, active_service in pairs(ports) do
			active_service:close();
			active_services:remove(service_name, interface, port, active_service);
			log("debug", "Removed listening service %s from [%s]:%d", service_name, interface, port);
		end
	end
	log("info", "Deactivated service '%s'", service_name);
end

function register_service(service_name, service_info)
	services[service_name] = service_info;

	if not active_services[service_name] then
		activate_service(service_name);
	end
	
	fire_event("service-added", { name = service_name, service = service_info });
	return true;
end


return _M;
