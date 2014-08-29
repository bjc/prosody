module:set_global();

local max_buffer_len = module:get_option_number("multiplex_buffer_size", 1024);

local portmanager = require "core.portmanager";

local available_services = {};

local function add_service(service)
	local multiplex_pattern = service.multiplex and service.multiplex.pattern;
	if multiplex_pattern then
		module:log("debug", "Adding multiplex service %q with pattern %q", service.name, multiplex_pattern);
		available_services[service] = multiplex_pattern;
	else
		module:log("debug", "Service %q is not multiplex-capable", service.name);
	end
end
module:hook("service-added", function (event) add_service(event.service); end);
module:hook("service-removed", function (event)	available_services[event.service] = nil; end);

for service_name, services in pairs(portmanager.get_registered_services()) do
	for i, service in ipairs(services) do
		add_service(service);
	end
end

local buffers = {};

local listener = { default_mode = "*a" };

function listener.onconnect()
end

function listener.onincoming(conn, data)
	if not data then return; end
	local buf = buffers[conn];
	buf = buf and buf..data or data;
	for service, multiplex_pattern in pairs(available_services) do
		if buf:match(multiplex_pattern) then
			module:log("debug", "Routing incoming connection to %s", service.name);
			local listener = service.listener;
			conn:setlistener(listener);
			local onconnect = listener.onconnect;
			if onconnect then onconnect(conn) end
			return listener.onincoming(conn, buf);
		end
	end
	if #buf > max_buffer_len then -- Give up
		conn:close();
	else
		buffers[conn] = buf;
	end
end

function listener.ondisconnect(conn, err)
	buffers[conn] = nil; -- warn if no buffer?
end

listener.ondetach = listener.ondisconnect;

module:provides("net", {
	name = "multiplex";
	config_prefix = "";
	listener = listener;
});

module:provides("net", {
	name = "multiplex_ssl";
	config_prefix = "ssl";
	listener = listener;
});
