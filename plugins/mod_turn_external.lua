local set = require "prosody.util.set";

local secret = module:get_option_string("turn_external_secret");
local host = module:get_option_string("turn_external_host", module.host);
local user = module:get_option_string("turn_external_user");
local port = module:get_option_number("turn_external_port", 3478);
local ttl = module:get_option_number("turn_external_ttl", 86400);
local tcp = module:get_option_boolean("turn_external_tcp", false);
local tls_port = module:get_option_number("turn_external_tls_port");

if not secret then
	module:log_status("error", "Failed to initialize: the 'turn_external_secret' option is not set in your configuration");
	return;
end

local services = set.new({ "stun-udp"; "turn-udp" });
if tcp then
	services:add("stun-tcp");
	services:add("turn-tcp");
end
if tls_port then
	services:add("turns-tcp");
end

module:depends "external_services";

for _, type in ipairs({ "stun"; "turn"; "turns" }) do
	for _, transport in ipairs({"udp"; "tcp"}) do
		if services:contains(type .. "-" .. transport) then
			module:add_item("external_service", {
				type = type;
				transport = transport;
				host = host;
				port = type == "turns" and tls_port or port;

				username = type == "turn" and user or nil;
				secret = type == "turn" and secret or nil;
				ttl = type == "turn" and ttl or nil;
			})
		end
	end
end
