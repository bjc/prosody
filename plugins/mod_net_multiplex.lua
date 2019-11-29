module:set_global();

local array = require "util.array";
local max_buffer_len = module:get_option_number("multiplex_buffer_size", 1024);

local portmanager = require "core.portmanager";

local available_services = {};
local service_by_protocol = {};
local available_protocols = array();

local function add_service(service)
	local multiplex_pattern = service.multiplex and service.multiplex.pattern;
	local protocol_name = service.multiplex and service.multiplex.protocol;
	if protocol_name then
		module:log("debug", "Adding multiplex service %q with protocol %q", service.name, protocol_name);
		service_by_protocol[protocol_name] = service;
		available_protocols:push(protocol_name);
	end
	if multiplex_pattern then
		module:log("debug", "Adding multiplex service %q with pattern %q", service.name, multiplex_pattern);
		available_services[service] = multiplex_pattern;
	elseif not protocol_name then
		module:log("debug", "Service %q is not multiplex-capable", service.name);
	end
	module:log("info", "available_protocols = %q", available_protocols);
end
module:hook("service-added", function (event) add_service(event.service); end);
module:hook("service-removed", function (event)
	available_services[event.service] = nil;
	if event.service.multiplex and event.service.multiplex.protocol then
		available_protocols:filter(function (p) return p ~= event.service.multiplex.protocol end);
		service_by_protocol[event.service.multiplex.protocol] = nil;
	end
end);

for _, services in pairs(portmanager.get_registered_services()) do
	for _, service in ipairs(services) do
		add_service(service);
	end
end

local buffers = {};

local listener = { default_mode = "*a" };

function listener.onconnect(conn)
	local sock = conn:socket();
	if sock.getalpn then
		local selected_proto = sock:getalpn();
		module:log("debug", "ALPN selected is %s", selected_proto);
		local service = service_by_protocol[selected_proto];
		if service then
			module:log("debug", "Routing incoming connection to %s", service.name);
			local next_listener = service.listener;
			conn:setlistener(next_listener);
			local onconnect = next_listener.onconnect;
			if onconnect then return onconnect(conn) end
		end
	end
end

function listener.onincoming(conn, data)
	if not data then return; end
	local buf = buffers[conn];
	buf = buf and buf..data or data;
	for service, multiplex_pattern in pairs(available_services) do
		if buf:match(multiplex_pattern) then
			module:log("debug", "Routing incoming connection to %s", service.name);
			local next_listener = service.listener;
			conn:setlistener(next_listener);
			local onconnect = next_listener.onconnect;
			if onconnect then onconnect(conn) end
			return next_listener.onincoming(conn, buf);
		end
	end
	if #buf > max_buffer_len then -- Give up
		conn:close();
	else
		buffers[conn] = buf;
	end
end

function listener.ondisconnect(conn)
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
	encryption = "ssl";
	ssl_config = {
		alpn = function ()
			return available_protocols;
		end;
	};
	listener = listener;
});
