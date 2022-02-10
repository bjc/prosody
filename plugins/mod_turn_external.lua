local set = require "util.set";

local secret = module:get_option_string("turn_external_secret");
local host = module:get_option_string("turn_external_host", module.host);
local user = module:get_option_string("turn_external_user");
local port = module:get_option_number("turn_external_port", 3478);
local ttl = module:get_option_number("turn_external_ttl", 86400);
local tcp = module:get_option_boolean("turn_external_tcp", false);

if not secret then error("mod_" .. module.name .. " requires that 'turn_external_secret' be set") end

local services = set.new({ "stun-udp"; "turn-udp" });
if tcp then
	services:add("stun-tcp");
	services:add("turn-tcp");
end

module:depends "external_services";

for _, type in ipairs({"stun"; "turn"}) do
	for _, transport in ipairs({"udp"; "tcp"}) do
		if services:contains(type .. "-" .. transport) then
			module:add_item("external_service", {
				type = type;
				transport = transport;
				host = host;
				port = port;

				username = type == "turn" and user or nil;
				secret = type == "turn" and secret or nil;
				ttl = type == "turn" and ttl or nil;
			})
		end
	end
end
