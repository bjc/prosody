local configmanager = require "prosody.core.configmanager";
local moduleapi = require "prosody.core.moduleapi";
local show_usage = require "prosody.util.prosodyctl".show_usage;
local show_warning = require "prosody.util.prosodyctl".show_warning;
local is_prosody_running = require "prosody.util.prosodyctl".isrunning;
local parse_args = require "prosody.util.argparse".parse;
local dependencies = require "prosody.util.dependencies";
local socket = require "socket";
local socket_url = require "socket.url";
local jid_split = require "prosody.util.jid".prepped_split;
local modulemanager = require "prosody.core.modulemanager";
local async = require "prosody.util.async";
local httputil = require "prosody.util.http";
local human_units = require "prosody.util.human.units";

local function api(host)
	return setmetatable({ name = "prosodyctl.check"; host = host; log = prosody.log }, { __index = moduleapi })
end

local function check_ojn(check_type, target_host)
	local http = require "prosody.net.http"; -- .new({});
	local json = require "prosody.util.json";

	local response, err = async.wait_for(http.request(
		("https://observe.jabber.network/api/v1/check/%s"):format(httputil.urlencode(check_type)),
		{
			method="POST",
			headers={["Accept"] = "application/json"; ["Content-Type"] = "application/json"},
			body=json.encode({target=target_host}),
		}));

	if not response then
		return false, err;
	end

	if response.code ~= 200 then
		return false, ("API replied with non-200 code: %d"):format(response.code);
	end

	local decoded_body, err = json.decode(response.body);
	if decoded_body == nil then
		return false, ("Failed to parse API JSON: %s"):format(err)
	end

	local success = decoded_body["success"];
	return success == true, nil;
end

local function check_probe(base_url, probe_module, target)
	local http = require "prosody.net.http"; -- .new({});
	local params = httputil.formencode({ module = probe_module; target = target })
	local response, err = async.wait_for(http.request(base_url .. "?" .. params));

	if not response then return false, err; end

	if response.code ~= 200 then return false, ("API replied with non-200 code: %d"):format(response.code); end

	for line in response.body:gmatch("[^\r\n]+") do
		local probe_success = line:match("^probe_success%s+(%d+)");

		if probe_success == "1" then
			return true;
		elseif probe_success == "0" then
			return false;
		end
	end
	return false, "Probe endpoint did not return a success status";
end

local function check_turn_service(turn_service, ping_service)
	local ip = require "prosody.util.ip";
	local stun = require "prosody.net.stun";

	local result = { warnings = {} };

	-- Create UDP socket for communication with the server
	local sock = assert(require "socket".udp());
	do
		local ok, err = sock:setsockname("*", 0);
		if not ok then
			result.error = "Unable to perform TURN test: setsockname: "..tostring(err);
			return result;
		end
		ok, err = sock:setpeername(turn_service.host, turn_service.port);
		if not ok then
			result.error = "Unable to perform TURN test: setpeername: "..tostring(err);
			return result;
		end
	end
	sock:settimeout(10);

	-- Helper function to receive a packet
	local function receive_packet()
		local raw_packet, err = sock:receive();
		if not raw_packet then
			return nil, err;
		end
		return stun.new_packet():deserialize(raw_packet);
	end

	-- Send a "binding" query, i.e. a request for our external IP/port
	local bind_query = stun.new_packet("binding", "request");
	bind_query:add_attribute("software", "prosodyctl check turn");
	sock:send(bind_query:serialize());

	local bind_result, err = receive_packet();
	if not bind_result then
		result.error = "No STUN response: "..err;
		return result;
	elseif bind_result:is_err_resp() then
		result.error = ("STUN server returned error: %d (%s)"):format(bind_result:get_error());
		return result;
	elseif not bind_result:is_success_resp() then
		result.error = ("Unexpected STUN response: %d (%s)"):format(bind_result:get_type());
		return result;
	end

	result.external_ip = bind_result:get_xor_mapped_address();
	if not result.external_ip then
		result.error = "STUN server did not return an address";
		return result;
	end
	if ip.new_ip(result.external_ip.address).private then
		table.insert(result.warnings, "STUN returned a private IP! Is the TURN server behind a NAT and misconfigured?");
	end

	-- Send a TURN "allocate" request. Expected to fail due to auth, but
	-- necessary to obtain a valid realm/nonce from the server.
	local pre_request = stun.new_packet("allocate", "request");
	sock:send(pre_request:serialize());

	local pre_result, err = receive_packet();
	if not pre_result then
		result.error = "No initial TURN response: "..err;
		return result;
	elseif pre_result:is_success_resp() then
		result.error = "TURN server does not have authentication enabled";
		return result;
	end

	local realm = pre_result:get_attribute("realm");
	local nonce = pre_result:get_attribute("nonce");

	if not realm then
		table.insert(result.warnings, "TURN server did not return an authentication realm. Is authentication enabled?");
	end
	if not nonce then
		table.insert(result.warnings, "TURN server did not return a nonce");
	end

	-- Use the configured secret to obtain temporary user/pass credentials
	local turn_user, turn_pass = stun.get_user_pass_from_secret(turn_service.secret);

	-- Send a TURN allocate request, will fail if auth is wrong
	local alloc_request = stun.new_packet("allocate", "request");
	alloc_request:add_requested_transport("udp");
	alloc_request:add_attribute("username", turn_user);
	if realm then
		alloc_request:add_attribute("realm", realm);
	end
	if nonce then
		alloc_request:add_attribute("nonce", nonce);
	end
	local key = stun.get_long_term_auth_key(realm or turn_service.host, turn_user, turn_pass);
	alloc_request:add_message_integrity(key);
	sock:send(alloc_request:serialize());

	-- Check the response
	local alloc_response, err = receive_packet();
	if not alloc_response then
		result.error = "TURN server did not response to allocation request: "..err;
		return result;
	elseif alloc_response:is_err_resp() then
		result.error = ("TURN server failed to create allocation: %d (%s)"):format(alloc_response:get_error());
		return result;
	elseif not alloc_response:is_success_resp() then
		result.error = ("Unexpected TURN response: %d (%s)"):format(alloc_response:get_type());
		return result;
	end

	result.relayed_addresses = alloc_response:get_xor_relayed_addresses();

	if not ping_service then
		-- Success! We won't be running the relay test.
		return result;
	end

	-- Run the relay test - i.e. send a binding request to ping_service
	-- and receive a response.

	-- Resolve the IP of the ping service
	local ping_host, ping_port = ping_service:match("^([^:]+):(%d+)$");
	if ping_host then
		ping_port = tonumber(ping_port);
	else
		-- Only a hostname specified, use default STUN port
		ping_host, ping_port = ping_service, 3478;
	end

	if ping_host == turn_service.host then
		result.error = ("Unable to perform ping test: please supply an external STUN server address. See https://prosody.im/doc/turn#prosodyctl-check");
		return result;
	end

	local ping_service_ip, err = socket.dns.toip(ping_host);
	if not ping_service_ip then
		result.error = "Unable to resolve ping service hostname: "..err;
		return result;
	end

	-- Ask the TURN server to allow packets from the ping service IP
	local perm_request = stun.new_packet("create-permission");
	perm_request:add_xor_peer_address(ping_service_ip);
	perm_request:add_attribute("username", turn_user);
	if realm then
		perm_request:add_attribute("realm", realm);
	end
	if nonce then
		perm_request:add_attribute("nonce", nonce);
	end
	perm_request:add_message_integrity(key);
	sock:send(perm_request:serialize());

	local perm_response, err = receive_packet();
	if not perm_response then
		result.error = "No response from TURN server when requesting peer permission: "..err;
		return result;
	elseif perm_response:is_err_resp() then
		result.error = ("TURN permission request failed: %d (%s)"):format(perm_response:get_error());
		return result;
	elseif not perm_response:is_success_resp() then
		result.error = ("Unexpected TURN response: %d (%s)"):format(perm_response:get_type());
		return result;
	end

	-- Ask the TURN server to relay a STUN binding request to the ping server
	local ping_data = stun.new_packet("binding"):serialize();

	local ping_request = stun.new_packet("send", "indication");
	ping_request:add_xor_peer_address(ping_service_ip, ping_port);
	ping_request:add_attribute("data", ping_data);
	ping_request:add_attribute("username", turn_user);
	if realm then
		ping_request:add_attribute("realm", realm);
	end
	if nonce then
		ping_request:add_attribute("nonce", nonce);
	end
	ping_request:add_message_integrity(key);
	sock:send(ping_request:serialize());

	local ping_response, err = receive_packet();
	if not ping_response then
		result.error = "No response from ping server ("..ping_service_ip.."): "..err;
		return result;
	elseif not ping_response:is_indication() or select(2, ping_response:get_method()) ~= "data" then
		result.error = ("Unexpected TURN response: %s %s"):format(select(2, ping_response:get_method()), select(2, ping_response:get_type()));
		return result;
	end

	local pong_data = ping_response:get_attribute("data");
	if not pong_data then
		result.error = "No data relayed from remote server";
		return result;
	end
	local pong = stun.new_packet():deserialize(pong_data);

	result.external_ip_pong = pong:get_xor_mapped_address();
	if not result.external_ip_pong then
		result.error = "Ping server did not return an address";
		return result;
	end

	local relay_address_found, relay_port_matches;
	for _, relayed_address in ipairs(result.relayed_addresses) do
		if relayed_address.address == result.external_ip_pong.address then
			relay_address_found = true;
			relay_port_matches = result.external_ip_pong.port == relayed_address.port;
		end
	end
	if not relay_address_found then
		table.insert(result.warnings, "TURN external IP vs relay address mismatch! Is the TURN server behind a NAT and misconfigured?");
	elseif not relay_port_matches then
		table.insert(result.warnings, "External port does not match reported relay port! This is probably caused by a NAT in front of the TURN server.");
	end

	--

	return result;
end

local function skip_bare_jid_hosts(host)
	if jid_split(host) then
		-- See issue #779
		return false;
	end
	return true;
end

local check_opts = {
	short_params = {
		h = "help", v = "verbose";
	};
	value_params = {
		ping = true;
	};
};

local function check(arg)
	if arg[1] == "help" or arg[1] == "--help" then
		show_usage([[check]], [[Perform basic checks on your Prosody installation]]);
		return 1;
	end
	local what = table.remove(arg, 1);
	local opts, opts_err, opts_info = parse_args(arg, check_opts);
	if opts_err == "missing-value" then
		print("Error: Expected a value after '"..opts_info.."'");
		return 1;
	elseif opts_err == "param-not-found" then
		print("Error: Unknown parameter: "..opts_info);
		return 1;
	end
	local array = require "prosody.util.array";
	local set = require "prosody.util.set";
	local it = require "prosody.util.iterators";
	local ok = true;
	local function contains_match(hayset, needle) for member in hayset do if member:find(needle) then return true end end end
	local function disabled_hosts(host, conf) return host ~= "*" and conf.enabled ~= false; end
	local function is_user_host(host, conf) return host ~= "*" and conf.component_module == nil; end
	local function is_component_host(host, conf) return host ~= "*" and conf.component_module ~= nil; end
	local function enabled_hosts() return it.filter(disabled_hosts, it.sorted_pairs(configmanager.getconfig())); end
	local function enabled_user_hosts() return it.filter(is_user_host, it.sorted_pairs(configmanager.getconfig())); end
	local function enabled_components() return it.filter(is_component_host, it.sorted_pairs(configmanager.getconfig())); end

	local checks = {};
	function checks.disabled()
		local disabled_hosts_set = set.new();
		for host in it.filter("*", pairs(configmanager.getconfig())) do
			if api(host):get_option_boolean("enabled") == false then
				disabled_hosts_set:add(host);
			end
		end
		if not disabled_hosts_set:empty() then
			local msg = "Checks will be skipped for these disabled hosts: %s";
			if what then msg = "These hosts are disabled: %s"; end
			show_warning(msg, tostring(disabled_hosts_set));
			if what then return 0; end
			print""
		end
	end
	function checks.config()
		print("Checking config...");

		if what == "config" then
			local files = configmanager.files();
			print("    The following configuration files have been loaded:");
			print("      -  "..table.concat(files, "\n      -  "));
		end

		local obsolete = set.new({ --> remove
			"archive_cleanup_interval",
			"dns_timeout",
			"muc_log_cleanup_interval",
			"s2s_dns_resolvers",
			"setgid",
			"setuid",
		});
		local function instead_use(kind, name, value)
			if kind == "option" then
				if value then
					return string.format("instead, use '%s = %q'", name, value);
				else
					return string.format("instead, use '%s'", name);
				end
			elseif kind == "module" then
				return string.format("instead, add %q to '%s'", name, value or "modules_enabled");
			elseif kind == "community" then
				return string.format("instead, add %q from %s", name, value or "prosody-modules");
			end
			return kind
		end
		local deprecated_replacements = {
			anonymous_login = instead_use("option", "authentication", "anonymous");
			daemonize = "instead, use the --daemonize/-D or --foreground/-F command line flags";
			disallow_s2s = instead_use("module", "s2s", "modules_disabled");
			no_daemonize = "instead, use the --daemonize/-D or --foreground/-F command line flags";
			require_encryption = "instead, use 'c2s_require_encryption' and 's2s_require_encryption'";
			vcard_compatibility = instead_use("community", "mod_compat_vcard");
			use_libevent = instead_use("option", "network_backend", "event");
			whitelist_registration_only = instead_use("option", "allowlist_registration_only");
			registration_whitelist = instead_use("option", "registration_allowlist");
			registration_blacklist = instead_use("option", "registration_blocklist");
			blacklist_on_registration_throttle_overload = instead_use("blocklist_on_registration_throttle_overload");
			cross_domain_bosh = "instead, use 'http_cors_override', see https://prosody.im/doc/http#cross-domain-cors-support";
			cross_domain_websocket = "instead, use 'http_cors_override', see https://prosody.im/doc/http#cross-domain-cors-support";
		};
		-- FIXME all the singular _port and _interface options are supposed to be deprecated too
		local deprecated_ports = { bosh = "http", legacy_ssl = "c2s_direct_tls" };
		local port_suffixes = set.new({ "port", "ports", "interface", "interfaces", "ssl" });
		for port, replacement in pairs(deprecated_ports) do
			for suffix in port_suffixes do
				local rsuffix = (suffix == "port" or suffix == "interface") and suffix.."s" or suffix;
				deprecated_replacements[port.."_"..suffix] = "instead, use '"..replacement.."_"..rsuffix.."'"
			end
		end
		local deprecated = set.new(array.collect(it.keys(deprecated_replacements)));
		local known_global_options = set.new({
			"access_control_allow_credentials",
			"access_control_allow_headers",
			"access_control_allow_methods",
			"access_control_max_age",
			"admin_socket",
			"body_size_limit",
			"bosh_max_inactivity",
			"bosh_max_polling",
			"bosh_max_wait",
			"buffer_size_limit",
			"c2s_close_timeout",
			"c2s_stanza_size_limit",
			"c2s_tcp_keepalives",
			"c2s_timeout",
			"component_stanza_size_limit",
			"component_tcp_keepalives",
			"consider_bosh_secure",
			"consider_websocket_secure",
			"console_banner",
			"console_prettyprint_settings",
			"daemonize",
			"gc",
			"http_default_host",
			"http_errors_always_show",
			"http_errors_default_message",
			"http_errors_detailed",
			"http_errors_messages",
			"http_max_buffer_size",
			"http_max_content_size",
			"installer_plugin_path",
			"limits",
			"limits_resolution",
			"log",
			"multiplex_buffer_size",
			"network_backend",
			"network_default_read_size",
			"network_settings",
			"openmetrics_allow_cidr",
			"openmetrics_allow_ips",
			"pidfile",
			"plugin_paths",
			"plugin_server",
			"prosodyctl_timeout",
			"prosody_group",
			"prosody_user",
			"run_as_root",
			"s2s_close_timeout",
			"s2s_insecure_domains",
			"s2s_require_encryption",
			"s2s_secure_auth",
			"s2s_secure_domains",
			"s2s_stanza_size_limit",
			"s2s_tcp_keepalives",
			"s2s_timeout",
			"statistics",
			"statistics_config",
			"statistics_interval",
			"tcp_keepalives",
			"tls_profile",
			"trusted_proxies",
			"umask",
			"use_dane",
			"use_ipv4",
			"use_ipv6",
			"websocket_frame_buffer_limit",
			"websocket_frame_fragment_limit",
			"websocket_get_response_body",
			"websocket_get_response_text",
		});
		local config = configmanager.getconfig();
		local global = api("*");
		-- Check that we have any global options (caused by putting a host at the top)
		if it.count(it.filter("log", pairs(config["*"]))) == 0 then
			ok = false;
			print("");
			print("    No global options defined. Perhaps you have put a host definition at the top")
			print("    of the config file? They should be at the bottom, see https://prosody.im/doc/configure#overview");
		end
		if it.count(enabled_hosts()) == 0 then
			ok = false;
			print("");
			if it.count(it.filter("*", pairs(config))) == 0 then
				print("    No hosts are defined, please add at least one VirtualHost section")
			elseif config["*"]["enabled"] == false then
				print("    No hosts are enabled. Remove enabled = false from the global section or put enabled = true under at least one VirtualHost section")
			else
				print("    All hosts are disabled. Remove enabled = false from at least one VirtualHost section")
			end
		end
		if not config["*"].modules_enabled then
			print("    No global modules_enabled is set?");
			local suggested_global_modules;
			for host, options in enabled_hosts() do --luacheck: ignore 213/host
				if not options.component_module and options.modules_enabled then
					suggested_global_modules = set.intersection(suggested_global_modules or set.new(options.modules_enabled), set.new(options.modules_enabled));
				end
			end
			if suggested_global_modules and not suggested_global_modules:empty() then
				print("    Consider moving these modules into modules_enabled in the global section:")
				print("    "..tostring(suggested_global_modules / function (x) return ("%q"):format(x) end));
			end
			print();
		end

		local function validate_module_list(host, name, modules)
			if modules == nil then
				return -- okay except for global section, checked separately
			end
			local t = type(modules)
			if t ~= "table" then
				print("    The " .. name .. " in the " .. host .. " section should not be a " .. t .. " but a list of strings, e.g.");
				print("    " .. name .. " = { \"name_of_module\", \"another_plugin\", }")
				print()
				ok = false
				return
			end
			for k, v in pairs(modules) do
				if type(k) ~= "number" or type(v) ~= "string" then
					print("    The " .. name .. " in the " .. host .. " section should be a list of strings, e.g.");
					print("    " .. name .. " = { \"name_of_module\", \"another_plugin\", }")
					print("    It should not contain key = value pairs, try putting them outside the {} brackets.");
					ok = false
					break
				end
			end
		end

		for host, options in enabled_hosts() do
			validate_module_list(host, "modules_enabled", options.modules_enabled);
			validate_module_list(host, "modules_disabled", options.modules_disabled);
		end

		do -- Check for modules enabled both normally and as components
			local modules = global:get_option_set("modules_enabled");
			for host, options in enabled_hosts() do
				local component_module = options.component_module;
				if component_module and modules:contains(component_module) then
					print(("    mod_%s is enabled both in modules_enabled and as Component %q %q"):format(component_module, host, component_module));
					print("    This means the service is enabled on all VirtualHosts as well as the Component.");
					print("    Are you sure this what you want? It may cause unexpected behaviour.");
				end
			end
		end

		-- Check for global options under hosts
		local global_options = set.new(it.to_array(it.keys(config["*"])));
		local obsolete_global_options = set.intersection(global_options, obsolete);
		if not obsolete_global_options:empty() then
			print("");
			print("    You have some obsolete options you can remove from the global section:");
			print("    "..tostring(obsolete_global_options))
			ok = false;
		end
		local deprecated_global_options = set.intersection(global_options, deprecated);
		if not deprecated_global_options:empty() then
			print("");
			print("    You have some deprecated options in the global section:");
			for option in deprecated_global_options do
				print(("    '%s' -- %s"):format(option, deprecated_replacements[option]));
			end
			ok = false;
		end
		for host, options in it.filter(function (h) return h ~= "*" end, pairs(configmanager.getconfig())) do
			local host_options = set.new(it.to_array(it.keys(options)));
			local misplaced_options = set.intersection(host_options, known_global_options);
			for name in pairs(options) do
				if name:match("^interfaces?")
				or name:match("_ports?$") or name:match("_interfaces?$")
				or (name:match("_ssl$") and not name:match("^[cs]2s_ssl$")) then
					misplaced_options:add(name);
				end
			end
			-- FIXME These _could_ be misplaced, but we would have to check where the corresponding module is loaded to be sure
			misplaced_options:exclude(set.new({ "external_service_port", "turn_external_port" }));
			if not misplaced_options:empty() then
				ok = false;
				print("");
				local n = it.count(misplaced_options);
				print("    You have "..n.." option"..(n>1 and "s " or " ").."set under "..host.." that should be");
				print("    in the global section of the config file, above any VirtualHost or Component definitions,")
				print("    see https://prosody.im/doc/configure#overview for more information.")
				print("");
				print("    You need to move the following option"..(n>1 and "s" or "")..": "..table.concat(it.to_array(misplaced_options), ", "));
			end
		end
		for host, options in enabled_hosts() do
			local host_options = set.new(it.to_array(it.keys(options)));
			local subdomain = host:match("^[^.]+");
			if not(host_options:contains("component_module")) and (subdomain == "jabber" or subdomain == "xmpp"
			   or subdomain == "chat" or subdomain == "im") then
				print("");
				print("    Suggestion: If "..host.. " is a new host with no real users yet, consider renaming it now to");
				print("     "..host:gsub("^[^.]+%.", "")..". You can use SRV records to redirect XMPP clients and servers to "..host..".");
				print("     For more information see: https://prosody.im/doc/dns");
			end
		end
		local all_modules = set.new(config["*"].modules_enabled);
		local all_options = set.new(it.to_array(it.keys(config["*"])));
		for host in enabled_hosts() do
			all_options:include(set.new(it.to_array(it.keys(config[host]))));
			all_modules:include(set.new(config[host].modules_enabled));
		end
		for mod in all_modules do
			if mod:match("^mod_") then
				print("");
				print("    Modules in modules_enabled should not have the 'mod_' prefix included.");
				print("    Change '"..mod.."' to '"..mod:match("^mod_(.*)").."'.");
			elseif mod:match("^auth_") then
				print("");
				print("    Authentication modules should not be added to modules_enabled,");
				print("    but be specified in the 'authentication' option.");
				print("    Remove '"..mod.."' from modules_enabled and instead add");
				print("        authentication = '"..mod:match("^auth_(.*)").."'");
				print("    For more information see https://prosody.im/doc/authentication");
			elseif mod:match("^storage_") then
				print("");
				print("    storage modules should not be added to modules_enabled,");
				print("    but be specified in the 'storage' option.");
				print("    Remove '"..mod.."' from modules_enabled and instead add");
				print("        storage = '"..mod:match("^storage_(.*)").."'");
				print("    For more information see https://prosody.im/doc/storage");
			end
		end
		if all_modules:contains("vcard") and all_modules:contains("vcard_legacy") then
			print("");
			print("    Both mod_vcard_legacy and mod_vcard are enabled but they conflict");
			print("    with each other. Remove one.");
		end
		if all_modules:contains("pep") and all_modules:contains("pep_simple") then
			print("");
			print("    Both mod_pep_simple and mod_pep are enabled but they conflict");
			print("    with each other. Remove one.");
		end
		if all_modules:contains("posix") then
			print("");
			print("    mod_posix is loaded in your configuration file, but it has");
			print("    been deprecated. You can safely remove it.");
		end
		if all_modules:contains("admin_telnet") then
			print("");
			print("    mod_admin_telnet is being replaced by mod_admin_shell (prosodyctl shell).");
			print("    To update and ensure all commands are available, simply change \"admin_telnet\" to \"admin_shell\"");
			print("    in your modules_enabled list.");
		end

		local load_failures = {};
		for mod_name in all_modules do
			local mod, err = modulemanager.loader:load_resource(mod_name, nil);
			if not mod then
				load_failures[mod_name] = err;
			end
		end

		if next(load_failures) ~= nil then
			print("");
			print("    The following modules failed to load:");
			print("");
			for mod_name, err in it.sorted_pairs(load_failures) do
				print(("        mod_%s: %s"):format(mod_name, err));
			end
			print("")
			print("    Check for typos and remove any obsolete/incompatible modules from your config.");
		end

		for host, host_config in pairs(config) do --luacheck: ignore 213/host
			if type(rawget(host_config, "storage")) == "string" and rawget(host_config, "default_storage") then
				print("");
				print("    The 'default_storage' option is not needed if 'storage' is set to a string.");
				break;
			end
		end

		for host, host_config in pairs(config) do --luacheck: ignore 213/host
			if type(rawget(host_config, "storage")) == "string" and rawget(host_config, "default_storage") then
				print("");
				print("    The 'default_storage' option is not needed if 'storage' is set to a string.");
				break;
			end
		end

		local require_encryption = set.intersection(all_options, set.new({
			"require_encryption", "c2s_require_encryption", "s2s_require_encryption"
		})):empty();
		local ssl = dependencies.softreq"ssl";
		if not ssl then
			if not require_encryption then
				print("");
				print("    You require encryption but LuaSec is not available.");
				print("    Connections will fail.");
				ok = false;
			end
		elseif not ssl.loadcertificate then
			if all_options:contains("s2s_secure_auth") then
				print("");
				print("    You have set s2s_secure_auth but your version of LuaSec does ");
				print("    not support certificate validation, so all s2s connections will");
				print("    fail.");
				ok = false;
			elseif all_options:contains("s2s_secure_domains") then
				local secure_domains = set.new();
				for host in enabled_hosts() do
					if api(host):get_option_boolean("s2s_secure_auth") then
						secure_domains:add("*");
					else
						secure_domains:include(api(host):get_option_set("s2s_secure_domains", {}));
					end
				end
				if not secure_domains:empty() then
					print("");
					print("    You have set s2s_secure_domains but your version of LuaSec does ");
					print("    not support certificate validation, so s2s connections to/from ");
					print("    these domains will fail.");
					ok = false;
				end
			end
		elseif require_encryption and not all_modules:contains("tls") then
			print("");
			print("    You require encryption but mod_tls is not enabled.");
			print("    Connections will fail.");
			ok = false;
		end

		do
			local registration_enabled_hosts = {};
			for host in enabled_hosts() do
				local host_modules, component = modulemanager.get_modules_for_host(host);
				local hostapi = api(host);
				local allow_registration = hostapi:get_option_boolean("allow_registration", false);
				local mod_register = host_modules:contains("register");
				local mod_register_ibr = host_modules:contains("register_ibr");
				local mod_invites_register = host_modules:contains("invites_register");
				local registration_invite_only = hostapi:get_option_boolean("registration_invite_only", true);
				local is_vhost = not component;
				if is_vhost and (mod_register_ibr or (mod_register and allow_registration))
				   and not (mod_invites_register and registration_invite_only) then
					table.insert(registration_enabled_hosts, host);
				end
			end
			if #registration_enabled_hosts > 0 then
				table.sort(registration_enabled_hosts);
				print("");
				print("    Public registration is enabled on:");
				print("        "..table.concat(registration_enabled_hosts, ", "));
				print("");
				print("        If this is intentional, review our guidelines on running a public server");
				print("        at https://prosody.im/doc/public_servers - otherwise, consider switching to");
				print("        invite-based registration, which is more secure.");
			end
		end

		do
			local orphan_components = {};
			local referenced_components = set.new();
			local enabled_hosts_set = set.new();
			local invalid_disco_items = {};
			for host in it.filter("*", pairs(configmanager.getconfig())) do
				local hostapi = api(host);
				if hostapi:get_option_boolean("enabled", true) then
					enabled_hosts_set:add(host);
					for _, disco_item in ipairs(hostapi:get_option_array("disco_items", {})) do
						if type(disco_item[1]) == "string" then
							referenced_components:add(disco_item[1]);
						else
							invalid_disco_items[host] = true;
						end
					end
				end
			end
			for host in it.filter(skip_bare_jid_hosts, enabled_hosts()) do
				local is_component = not not select(2, modulemanager.get_modules_for_host(host));
				if is_component then
					local parent_domain = host:match("^[^.]+%.(.+)$");
					local is_orphan = not (enabled_hosts_set:contains(parent_domain) or referenced_components:contains(host));
					if is_orphan then
						table.insert(orphan_components, host);
					end
				end
			end

			if next(invalid_disco_items) ~= nil then
				print("");
				print("    Some hosts in your configuration file have an invalid 'disco_items' option.");
				print("    This may cause further errors, such as unreferenced components.");
				print("");
				for host in it.sorted_pairs(invalid_disco_items) do
					print("      - "..host);
				end
				print("");
			end

			if #orphan_components > 0 then
				table.sort(orphan_components);
				print("");
				print("    Your configuration contains the following unreferenced components:\n");
				print("        "..table.concat(orphan_components, "\n        "));
				print("");
				print("    Clients may not be able to discover these services because they are not linked to");
				print("    any VirtualHost. They are automatically linked if they are direct subdomains of a");
				print("    VirtualHost. Alternatively, you can explicitly link them using the disco_items option.");
				print("    For more information see https://prosody.im/doc/modules/mod_disco#items");
			end
		end

		-- Check hostname validity
		do
			local idna = require "prosody.util.encodings".idna;
			local invalid_hosts = {};
			local alabel_hosts = {};
			for host in it.filter("*", pairs(configmanager.getconfig())) do
				local _, h, _ = jid_split(host);
				if not h or not idna.to_ascii(h) then
					table.insert(invalid_hosts, host);
				else
					for label in h:gmatch("[^%.]+") do
						if label:match("^xn%-%-") then
							table.insert(alabel_hosts, host);
							break;
						end
					end
				end
			end

			if #invalid_hosts > 0 then
				table.sort(invalid_hosts);
				print("");
				print("    Your configuration contains invalid host names:");
				print("        "..table.concat(invalid_hosts, "\n        "));
				print("");
				print("    Clients may not be able to log in to these hosts, or you may not be able to");
				print("    communicate with remote servers.");
				print("    Use a valid domain name to correct this issue.");
			end

			if #alabel_hosts > 0 then
				table.sort(alabel_hosts);
				print("");
				print("    Your configuration contains incorrectly-encoded hostnames:");
				for _, ahost in ipairs(alabel_hosts) do
					print(("        '%s' (should be '%s')"):format(ahost, idna.to_unicode(ahost)));
				end
				print("");
				print("    Clients may not be able to log in to these hosts, or you may not be able to");
				print("    communicate with remote servers.");
				print("    To correct this issue, use the Unicode version of the domain in Prosody's config file.");
			end

			if #invalid_hosts > 0 or #alabel_hosts > 0 then
				print("");
				print("    WARNING: Changing the name of a VirtualHost in Prosody's config file");
				print("             WILL NOT migrate any existing data (user accounts, etc.) to the new name.");
				ok = false;
			end
		end

		-- Check features
		do
			local missing_features = {};
			for host in enabled_user_hosts() do
				local all_features = checks.features(host, true);
				if not all_features then
					table.insert(missing_features, host);
				end
			end
			if #missing_features > 0 then
				print("");
				print("    Some of your hosts may be missing features due to a lack of configuration.");
				print("    For more details, use the 'prosodyctl check features' command.");
			end
		end

		print("Done.\n");
	end
	function checks.dns()
		local dns = require "prosody.net.dns";
		pcall(function ()
			local unbound = require"prosody.net.unbound";
			dns = unbound.dns;
		end)
		local idna = require "prosody.util.encodings".idna;
		local ip = require "prosody.util.ip";
		local global = api("*");
		local c2s_ports = global:get_option_set("c2s_ports", {5222});
		local s2s_ports = global:get_option_set("s2s_ports", {5269});
		local c2s_tls_ports = global:get_option_set("c2s_direct_tls_ports", {});
		local s2s_tls_ports = global:get_option_set("s2s_direct_tls_ports", {});

		local global_enabled = set.new();
		for host in enabled_hosts() do
			global_enabled:include(modulemanager.get_modules_for_host(host));
		end
		if global_enabled:contains("net_multiplex") then
			local multiplex_ports = global:get_option_set("ports", {});
			local multiplex_tls_ports = global:get_option_set("ssl_ports", {});
			if not multiplex_ports:empty() then
				c2s_ports = c2s_ports + multiplex_ports;
				s2s_ports = s2s_ports + multiplex_ports;
			end
			if not multiplex_tls_ports:empty() then
				c2s_tls_ports = c2s_tls_ports + multiplex_tls_ports;
				s2s_tls_ports = s2s_tls_ports + multiplex_tls_ports;
			end
		end

		local c2s_srv_required, s2s_srv_required, c2s_tls_srv_required, s2s_tls_srv_required;
		if not c2s_ports:contains(5222) then
			c2s_srv_required = true;
		end
		if not s2s_ports:contains(5269) then
			s2s_srv_required = true;
		end
		if not c2s_tls_ports:empty() then
			c2s_tls_srv_required = true;
		end
		if not s2s_tls_ports:empty() then
			s2s_tls_srv_required = true;
		end

		local problem_hosts = set.new();

		local external_addresses, internal_addresses = set.new(), set.new();

		local fqdn = socket.dns.tohostname(socket.dns.gethostname());
		if fqdn then
			local fqdn_a = idna.to_ascii(fqdn);
			if fqdn_a then
				local res = dns.lookup(fqdn_a, "A");
				if res then
					for _, record in ipairs(res) do
						external_addresses:add(record.a);
					end
				end
			end
			if fqdn_a then
				local res = dns.lookup(fqdn_a, "AAAA");
				if res then
					for _, record in ipairs(res) do
						external_addresses:add(record.aaaa);
					end
				end
			end
		end

		local local_addresses = require"prosody.util.net".local_addresses() or {};

		for addr in it.values(local_addresses) do
			if not ip.new_ip(addr).private then
				external_addresses:add(addr);
			else
				internal_addresses:add(addr);
			end
		end

		-- Allow admin to specify additional (e.g. undiscoverable) IP addresses in the config
		for _, address in ipairs(global:get_option_array("external_addresses", {})) do
			external_addresses:add(address);
		end

		if external_addresses:empty() then
			print("");
			print("   Failed to determine the external addresses of this server. Checks may be inaccurate.");
			print("   If you know the correct external addresses you can specify them in the config like:")
			print("      external_addresses = { \"192.0.2.34\", \"2001:db8::abcd:1234\" }")
			c2s_srv_required, s2s_srv_required = true, true;
		end

		local v6_supported = not not socket.tcp6;
		local use_ipv4 = global:get_option_boolean("use_ipv4", true);
		local use_ipv6 = global:get_option_boolean("use_ipv6", true);

		local function trim_dns_name(n)
			return (n:gsub("%.$", ""));
		end

		local unknown_addresses = set.new();

		local function is_valid_domain(domain)
			return idna.to_ascii(domain) ~= nil;
		end

		for jid in it.filter(is_valid_domain, enabled_hosts()) do
			local all_targets_ok, some_targets_ok = true, false;
			local node, host = jid_split(jid);

			local modules, component_module = modulemanager.get_modules_for_host(host);
			if component_module then
				modules:add(component_module);
			end

			-- TODO Refactor these DNS SRV checks since they are very similar
			-- FIXME Suggest concrete actionable steps to correct issues so that
			-- users don't have to copy-paste the message into the support chat and
			-- ask what to do about it.
			local is_component = not not component_module;
			print("Checking DNS for "..(is_component and "component" or "host").." "..jid.."...");
			if node then
				print("Only the domain part ("..host..") is used in DNS.")
			end
			local target_hosts = set.new();
			if modules:contains("c2s") then
				local res = dns.lookup("_xmpp-client._tcp."..idna.to_ascii(host)..".", "SRV");
				if res and #res > 0 then
					for _, record in ipairs(res) do
						if record.srv.target == "." then -- TODO is this an error if mod_c2s is enabled?
							print("    'xmpp-client' service disabled by pointing to '.'"); -- FIXME Explain better what this is
							break;
						end
						local target = trim_dns_name(record.srv.target);
						target_hosts:add(target);
						if not c2s_ports:contains(record.srv.port) then
							print("    SRV target "..target.." contains unknown client port: "..record.srv.port);
						end
					end
				else
					if c2s_srv_required then
						print("    No _xmpp-client SRV record found for "..host..", but it looks like you need one.");
						all_targets_ok = false;
					else
						target_hosts:add(host);
					end
				end
			end
			if modules:contains("c2s") then
				local res = dns.lookup("_xmpps-client._tcp."..idna.to_ascii(host)..".", "SRV");
				if res and #res > 0 then
					for _, record in ipairs(res) do
						if record.srv.target == "." then -- TODO is this an error if mod_c2s is enabled?
							print("    'xmpps-client' service disabled by pointing to '.'"); -- FIXME Explain better what this is
							break;
						end
						local target = trim_dns_name(record.srv.target);
						target_hosts:add(target);
						if not c2s_tls_ports:contains(record.srv.port) then
							print("    SRV target "..target.." contains unknown Direct TLS client port: "..record.srv.port);
						end
					end
				elseif c2s_tls_srv_required then
					print("    No _xmpps-client SRV record found for "..host..", but it looks like you need one.");
					all_targets_ok = false;
				end
			end
			if modules:contains("s2s") then
				local res = dns.lookup("_xmpp-server._tcp."..idna.to_ascii(host)..".", "SRV");
				if res and #res > 0 then
					for _, record in ipairs(res) do
						if record.srv.target == "." then -- TODO Is this an error if mod_s2s is enabled?
							print("    'xmpp-server' service disabled by pointing to '.'"); -- FIXME Explain better what this is
							break;
						end
						local target = trim_dns_name(record.srv.target);
						target_hosts:add(target);
						if not s2s_ports:contains(record.srv.port) then
							print("    SRV target "..target.." contains unknown server port: "..record.srv.port);
						end
					end
				else
					if s2s_srv_required then
						print("    No _xmpp-server SRV record found for "..host..", but it looks like you need one.");
						all_targets_ok = false;
					else
						target_hosts:add(host);
					end
				end
			end
			if modules:contains("s2s") then
				local res = dns.lookup("_xmpps-server._tcp."..idna.to_ascii(host)..".", "SRV");
				if res and #res > 0 then
					for _, record in ipairs(res) do
						if record.srv.target == "." then -- TODO is this an error if mod_s2s is enabled?
							print("    'xmpps-server' service disabled by pointing to '.'"); -- FIXME Explain better what this is
							break;
						end
						local target = trim_dns_name(record.srv.target);
						target_hosts:add(target);
						if not s2s_tls_ports:contains(record.srv.port) then
							print("    SRV target "..target.." contains unknown Direct TLS server port: "..record.srv.port);
						end
					end
				elseif s2s_tls_srv_required then
					print("    No _xmpps-server SRV record found for "..host..", but it looks like you need one.");
					all_targets_ok = false;
				end
			end
			if target_hosts:empty() then
				target_hosts:add(host);
			end

			if target_hosts:contains("localhost") then
				print("    Target 'localhost' cannot be accessed from other servers");
				target_hosts:remove("localhost");
			end

			local function check_record(name, rtype)
				local res, err = dns.lookup(name, rtype);
				if err then
					print("    Problem looking up "..rtype.." record for '"..name.."': "..err);
				elseif res and res.bogus then
					print("    Problem looking up "..rtype.." record for '"..name.."': "..res.bogus);
				elseif res and res.rcode and res.rcode ~= 0 and res.rcode ~= 3 then
					print("    Problem looking up "..rtype.." record for '"..name.."': "..res.status);
				end
				return res and #res > 0;
			end

			local function check_address(target)
				local prob = {};
				local aname = idna.to_ascii(target);
				if not aname then
					print("    '" .. target .. "' is not a valid hostname");
					return prob;
				end
				if use_ipv4 and not check_record(aname, "A") then table.insert(prob, "A"); end
				if use_ipv6 and not check_record(aname, "AAAA") then table.insert(prob, "AAAA"); end
				return prob;
			end

			if modules:contains("proxy65") then
				local proxy65_target = api(host):get_option_string("proxy65_address", host);
				if type(proxy65_target) == "string" then
					local prob = check_address(proxy65_target);
					if #prob > 0 then
						print("    File transfer proxy "..proxy65_target.." has no "..table.concat(prob, "/")
						.." record. Create one or set 'proxy65_address' to the correct host/IP.");
					end
				else
					print("    proxy65_address for "..host.." should be set to a string, unable to perform DNS check");
				end
			end

			local known_http_modules = set.new { "bosh"; "http_files"; "http_file_share"; "http_openmetrics"; "websocket" };

			if modules:contains("http") or not set.intersection(modules, known_http_modules):empty()
				or contains_match(modules, "^http_") or contains_match(modules, "_web$") then

				local http_host = api(host):get_option_string("http_host", host);
				local http_internal_host = http_host;
				local http_url = api(host):get_option_string("http_external_url");
				if http_url then
					local url_parse = require "socket.url".parse;
					local external_url_parts = url_parse(http_url);
					if external_url_parts then
						http_host = external_url_parts.host;
					else
						print("    The 'http_external_url' setting is not a valid URL");
					end
				end

				local prob = check_address(http_host);
				if #prob > 1 then
					print("    HTTP service " .. http_host .. " has no " .. table.concat(prob, "/") .. " record. Create one or change "
									.. (http_url and "'http_external_url'" or "'http_host'").." to the correct host.");
				end

				if http_host ~= http_internal_host then
					print("    Ensure the reverse proxy sets the HTTP Host header to '" .. http_internal_host .. "'");
				end
			end

			if not use_ipv4 and not use_ipv6 then
				print("    Both IPv6 and IPv4 are disabled, Prosody will not listen on any ports");
				print("    nor be able to connect to any remote servers.");
				all_targets_ok = false;
			end

			for target_host in target_hosts do
				local host_ok_v4, host_ok_v6;
				do
					local res = dns.lookup(idna.to_ascii(target_host), "A");
					if res then
						for _, record in ipairs(res) do
							if external_addresses:contains(record.a) then
								some_targets_ok = true;
								host_ok_v4 = true;
							elseif internal_addresses:contains(record.a) then
								host_ok_v4 = true;
								some_targets_ok = true;
								print("    "..target_host.." A record points to internal address, external connections might fail");
							else
								print("    "..target_host.." A record points to unknown address "..record.a);
								unknown_addresses:add(record.a);
								all_targets_ok = false;
							end
						end
					end
				end
				do
					local res = dns.lookup(idna.to_ascii(target_host), "AAAA");
					if res then
						for _, record in ipairs(res) do
							if external_addresses:contains(record.aaaa) then
								some_targets_ok = true;
								host_ok_v6 = true;
							elseif internal_addresses:contains(record.aaaa) then
								host_ok_v6 = true;
								some_targets_ok = true;
								print("    "..target_host.." AAAA record points to internal address, external connections might fail");
							else
								print("    "..target_host.." AAAA record points to unknown address "..record.aaaa);
								unknown_addresses:add(record.aaaa);
								all_targets_ok = false;
							end
						end
					end
				end

				if host_ok_v4 and not use_ipv4 then
					print("    Host "..target_host.." does seem to resolve to this server but IPv4 has been disabled");
					all_targets_ok = false;
				end

				if host_ok_v6 and not use_ipv6 then
					print("    Host "..target_host.." does seem to resolve to this server but IPv6 has been disabled");
					all_targets_ok = false;
				end

				local bad_protos = {}
				if use_ipv4 and not host_ok_v4 then
					table.insert(bad_protos, "IPv4");
				end
				if use_ipv6 and not host_ok_v6 then
					table.insert(bad_protos, "IPv6");
				end
				if #bad_protos > 0 then
					print("    Host "..target_host.." does not seem to resolve to this server ("..table.concat(bad_protos, "/")..")");
				end
				if host_ok_v6 and not v6_supported then
					print("    Host "..target_host.." has AAAA records, but your version of LuaSocket does not support IPv6.");
					print("      Please see https://prosody.im/doc/ipv6 for more information.");
				elseif host_ok_v6 and not use_ipv6 then
					print("    Host "..target_host.." has AAAA records, but IPv6 is disabled.");
					-- TODO Tell them to drop the AAAA records or enable IPv6?
					print("      Please see https://prosody.im/doc/ipv6 for more information.");
				end
			end
			if not all_targets_ok then
				print("    "..(some_targets_ok and "Only some" or "No").." targets for "..host.." appear to resolve to this server.");
				if is_component then
					print("    DNS records are necessary if you want users on other servers to access this component.");
				end
				problem_hosts:add(host);
			end
			print("");
		end
		if not problem_hosts:empty() then
			if not unknown_addresses:empty() then
				print("");
				print("Some of your DNS records point to unknown IP addresses. This may be expected if your server");
				print("is behind a NAT or proxy. The unrecognized addresses were:");
				print("");
				print("    Unrecognized: "..tostring(unknown_addresses));
				print("");
				print("The addresses we found on this system are:");
				print("");
				print("    Internal: "..tostring(internal_addresses));
				print("    External: "..tostring(external_addresses));
				print("")
				print("If the list of external external addresses is incorrect you can specify correct addresses in the config:")
				print("    external_addresses = { \"192.0.2.34\", \"2001:db8::abcd:1234\" }")
			end
			print("");
			print("For more information about DNS configuration please see https://prosody.im/doc/dns");
			print("");
			ok = false;
		end
	end
	function checks.certs()
		local cert_ok;
		print"Checking certificates..."
		local x509_verify_identity = require"prosody.util.x509".verify_identity;
		local use_dane = configmanager.get("*", "use_dane");
		local pem2der = require"prosody.util.x509".pem2der;
		local sha256 = require"prosody.util.hashes".sha256;
		local create_context = require "prosody.core.certmanager".create_context;
		local ssl = dependencies.softreq"ssl";
		-- local datetime_parse = require"util.datetime".parse_x509;
		local load_cert = ssl and ssl.loadcertificate;
		-- or ssl.cert_from_pem
		if not ssl then
			print("LuaSec not available, can't perform certificate checks")
			if what == "certs" then cert_ok = false end
		elseif not load_cert then
			print("This version of LuaSec (" .. ssl._VERSION .. ") does not support certificate checking");
			cert_ok = false
		else
			for host in it.filter(skip_bare_jid_hosts, enabled_hosts()) do
				local modules = modulemanager.get_modules_for_host(host);
				print("Checking certificate for "..host);
				-- First, let's find out what certificate this host uses.
				local host_ssl_config = configmanager.rawget(host, "ssl")
					or configmanager.rawget(host:match("%.(.*)"), "ssl");
				local global_ssl_config = configmanager.rawget("*", "ssl");
				local ctx_ok, err, ssl_config = create_context(host, "server", host_ssl_config, global_ssl_config);
				if not ctx_ok then
					print("  Error: "..err);
					cert_ok = false
				elseif not ssl_config.certificate then
					print("  No 'certificate' found for "..host)
					cert_ok = false
				elseif not ssl_config.key then
					print("  No 'key' found for "..host)
					cert_ok = false
				else
					local key, err = io.open(ssl_config.key); -- Permissions check only
					if not key then
						print("    Could not open "..ssl_config.key..": "..err);
						cert_ok = false
					else
						key:close();
					end
					local cert_fh, err = io.open(ssl_config.certificate); -- Load the file.
					if not cert_fh then
						print("    Could not open "..ssl_config.certificate..": "..err);
						cert_ok = false
					else
						print("  Certificate: "..ssl_config.certificate)
						local cert = load_cert(cert_fh:read"*a"); cert_fh:close();
						if not cert:validat(os.time()) then
							print("    Certificate has expired.")
							cert_ok = false
						elseif not cert:validat(os.time() + 86400) then
							print("    Certificate expires within one day.")
							cert_ok = false
						elseif not cert:validat(os.time() + 86400*7) then
							print("    Certificate expires within one week.")
						elseif not cert:validat(os.time() + 86400*31) then
							print("    Certificate expires within one month.")
						end
						if modules:contains("c2s") and not x509_verify_identity(host, "_xmpp-client", cert) then
							print("    Not valid for client connections to "..host..".")
							cert_ok = false
						end
						local anon = api(host):get_option_string("authentication", "internal_hashed") == "anonymous";
						local anon_s2s = api(host):get_option_boolean("allow_anonymous_s2s", false);
						if modules:contains("s2s") and (anon_s2s or not anon) and not x509_verify_identity(host, "_xmpp-server", cert) then
							print("    Not valid for server-to-server connections to "..host..".")
							cert_ok = false
						end

						local known_http_modules = set.new { "bosh"; "http_files"; "http_file_share"; "http_openmetrics"; "websocket" };
						local http_loaded = modules:contains("http")
							or not set.intersection(modules, known_http_modules):empty()
							or contains_match(modules, "^http_")
							or contains_match(modules, "_web$");

						local http_host = api(host):get_option_string("http_host", host);
						if api(host):get_option_string("http_external_url") then
							-- Assumed behind a reverse proxy
							http_loaded = false;
						end
						if http_loaded and not x509_verify_identity(http_host, nil, cert) then
							print("    Not valid for HTTPS connections to "..http_host..".")
							cert_ok = false
						end
						if use_dane then
							if cert.pubkey then
								print("    DANE: TLSA 3 1 1 "..sha256(pem2der(cert:pubkey()), true))
							elseif cert.pem then
								print("    DANE: TLSA 3 0 1 "..sha256(pem2der(cert:pem()), true))
							end
						end
					end
				end
			end
		end
		if cert_ok == false then
			print("")
			print("For more information about certificates please see https://prosody.im/doc/certificates");
			ok = false
		end
		print("")
	end
	-- intentionally not doing this by default
	function checks.connectivity()
		local _, prosody_is_running = is_prosody_running();
		if api("*"):get_option_string("pidfile") and not prosody_is_running then
			print("Prosody does not appear to be running, which is required for this test.");
			print("Start it and then try again.");
			return 1;
		end

		local checker = "observe.jabber.network";
		local probe_instance;
		local probe_modules = {
			["xmpp-client"] = "c2s_normal_auth";
			["xmpp-server"] = "s2s_normal";
			["xmpps-client"] = nil; -- TODO
			["xmpps-server"] = nil; -- TODO
		};
		local probe_settings = api("*"):get_option_string("connectivity_probe");
		if type(probe_settings) == "string" then
			probe_instance = probe_settings;
		elseif type(probe_settings) == "table" and type(probe_settings.url) == "string" then
			probe_instance = probe_settings.url;
			if type(probe_settings.modules) == "table" then
				probe_modules = probe_settings.modules;
			end
		elseif probe_settings ~= nil then
			print("The 'connectivity_probe' setting not understood.");
			print("Expected an URL or a table with 'url' and 'modules' fields");
			print("See https://prosody.im/doc/prosodyctl#check for more information."); -- FIXME
			return 1;
		end

		local check_api;
		if probe_instance then
			local parsed_url = socket_url.parse(probe_instance);
			if not parsed_url then
				print(("'connectivity_probe' is not a valid URL: %q"):format(probe_instance));
				print("Set it to the URL of an XMPP Blackbox Exporter instance and try again");
				return 1;
			end
			checker = parsed_url.host;

			function check_api(protocol, host)
				local target = socket_url.build({scheme="xmpp",path=host});
				local probe_module = probe_modules[protocol];
				if not probe_module then
					return nil, "Checking protocol '"..protocol.."' is currently unsupported";
				end
				return check_probe(probe_instance, probe_module, target);
			end
		else
			check_api = check_ojn;
		end

		for host in it.filter(skip_bare_jid_hosts, enabled_hosts()) do
			local modules, component_module = modulemanager.get_modules_for_host(host);
			if component_module then
				modules:add(component_module)
			end

			print("Checking external connectivity for "..host.." via "..checker)
			local function check_connectivity(protocol)
				local success, err = check_api(protocol, host);
				if not success and err ~= nil then
					print(("  %s: Failed to request check at API: %s"):format(protocol, err))
				elseif success then
					print(("  %s: Works"):format(protocol))
				else
					print(("  %s: Check service failed to establish (secure) connection"):format(protocol))
					ok = false
				end
			end

			if modules:contains("c2s") then
				check_connectivity("xmpp-client")
				if not api("*"):get_option_set("c2s_direct_tls_ports", {}):empty() then
					check_connectivity("xmpps-client");
				end
			end

			if modules:contains("s2s") then
				check_connectivity("xmpp-server")
				if not api("*"):get_option_set("s2s_direct_tls_ports", {}):empty() then
					check_connectivity("xmpps-server");
				end
			end

			print()
		end
		print("Note: The connectivity check only checks the reachability of the domain.")
		print("Note: It does not ensure that the check actually reaches this specific prosody instance.")
	end

	function checks.turn()
		local turn_enabled_hosts = {};
		local turn_services = {};

		for host in enabled_hosts() do
			local has_external_turn = modulemanager.get_modules_for_host(host):contains("turn_external");
			if has_external_turn then
				local hostapi = api(host);
				table.insert(turn_enabled_hosts, host);
				local turn_host = hostapi:get_option_string("turn_external_host", host);
				local turn_port = hostapi:get_option_number("turn_external_port", 3478);
				local turn_secret = hostapi:get_option_string("turn_external_secret");
				if not turn_secret then
					print("Error: Your configuration is missing a turn_external_secret for "..host);
					print("Error: TURN will not be advertised for this host.");
					ok = false;
				else
					local turn_id = ("%s:%d"):format(turn_host, turn_port);
					if turn_services[turn_id] and turn_services[turn_id].secret ~= turn_secret then
						print("Error: Your configuration contains multiple differing secrets");
						print("       for the TURN service at "..turn_id.." - we will only test one.");
					elseif not turn_services[turn_id] then
						turn_services[turn_id] = {
							host = turn_host;
							port = turn_port;
							secret = turn_secret;
						};
					end
				end
			end
		end

		if what == "turn" then
			local count = it.count(pairs(turn_services));
			if count == 0 then
				print("Error: Unable to find any TURN services configured. Enable mod_turn_external!");
				ok = false;
			else
				print("Identified "..tostring(count).." TURN services.");
				print("");
			end
		end

		for turn_id, turn_service in pairs(turn_services) do
			print("Testing TURN service "..turn_id.."...");

			local result = check_turn_service(turn_service, opts.ping);
			if #result.warnings > 0 then
				print(("%d warnings:\n"):format(#result.warnings));
				print("    "..table.concat(result.warnings, "\n    "));
				print("");
			end

			if opts.verbose then
				if result.external_ip then
					print(("External IP: %s"):format(result.external_ip.address));
				end
				if result.relayed_addresses then
					for i, relayed_address in ipairs(result.relayed_addresses) do
						print(("Relayed address %d: %s:%d"):format(i, relayed_address.address, relayed_address.port));
					end
				end
				if result.external_ip_pong then
					print(("TURN external address: %s:%d"):format(result.external_ip_pong.address, result.external_ip_pong.port));
				end
			end

			if result.error then
				print("Error: "..result.error.."\n");
				ok = false;
			else
				print("Success!\n");
			end
		end
	end

	function checks.features(check_host, quiet)
		if not quiet then
			print("Feature report");
		end

		local common_subdomains = {
			http_file_share = "share";
			muc = "groups";
		};

		local recommended_component_modules = {
			muc = { "muc_mam" };
		};

		local function print_feature_status(feature, host)
			if quiet then return; end
			print("", feature.ok and "OK" or "(!)", feature.name);
			if feature.desc then
				print("", "", feature.desc);
				print("");
			end
			if not feature.ok then
				if feature.lacking_modules then
					table.sort(feature.lacking_modules);
					print("", "", "Suggested modules: ");
					for _, module in ipairs(feature.lacking_modules) do
						print("", "", ("  - %s: https://prosody.im/doc/modules/mod_%s"):format(module, module));
					end
				end
				if feature.lacking_components then
					table.sort(feature.lacking_components);
					for _, component_module in ipairs(feature.lacking_components) do
						local subdomain = common_subdomains[component_module];
						local recommended_mods = recommended_component_modules[component_module];
						if subdomain then
							print("", "", "Suggested component:");
							print("");
							print("", "", "", ("-- Documentation: https://prosody.im/doc/modules/mod_%s"):format(component_module));
							print("", "", "", ("Component %q %q"):format(subdomain.."."..host, component_module));
							if recommended_mods then
								print("", "", "", "    modules_enabled = {");
								table.sort(recommended_mods);
								for _, mod in ipairs(recommended_mods) do
									print("", "", "", ("        %q;"):format(mod));
								end
								print("", "", "", "    }");
							end
						else
							print("", "", ("Suggested component: %s"):format(component_module));
						end
					end
					print("");
					print("", "", "If you have already configured any of these components, they may not be");
					print("", "", "linked correctly to "..host..". For more info see https://prosody.im/doc/components");
				end
				if feature.lacking_component_modules then
					table.sort(feature.lacking_component_modules, function (a, b)
						return a.host < b.host;
					end);
					for _, problem in ipairs(feature.lacking_component_modules) do
						local hostapi = api(problem.host);
						local current_modules_enabled = hostapi:get_option_array("modules_enabled", {});
						print("", "", ("Component %q is missing the following modules: %s"):format(problem.host, table.concat(problem.missing_mods)));
						print("");
						print("","", "Add the missing modules to your modules_enabled under the Component, like this:");
						print("");
						print("");
						print("", "", "", ("-- Documentation: https://prosody.im/doc/modules/mod_%s"):format(problem.component_module));
						print("", "", "", ("Component %q %q"):format(problem.host, problem.component_module));
						print("", "", "", ("    modules_enabled = {"));
						for _, mod in ipairs(current_modules_enabled) do
							print("", "", "", ("        %q;"):format(mod));
						end
						for _, mod in ipairs(problem.missing_mods) do
							print("", "", "", ("        %q; -- Add this!"):format(mod));
						end
						print("", "", "", ("    }"));
					end
				end
			end
			if feature.meta then
				for k, v in it.sorted_pairs(feature.meta) do
					print("", "", (" - %s: %s"):format(k, v));
				end
			end
			print("");
		end

		local all_ok = true;

		local config = configmanager.getconfig();

		local f, s, v;
		if check_host then
			f, s, v = it.values({ check_host });
		else
			f, s, v = enabled_user_hosts();
		end

		for host in f, s, v do
			local modules_enabled = set.new(config["*"].modules_enabled);
			modules_enabled:include(set.new(config[host].modules_enabled));

			-- { [component_module] = { hostname1, hostname2, ... } }
			local host_components = setmetatable({}, { __index = function (t, k) return rawset(t, k, {})[k]; end });

			do
				local hostapi = api(host);

				-- Find implicitly linked components
				for other_host in enabled_components() do
					local parent_host = other_host:match("^[^.]+%.(.+)$");
					if parent_host == host then
						local component_module = configmanager.get(other_host, "component_module");
						if component_module then
							table.insert(host_components[component_module], other_host);
						end
					end
				end

				-- And components linked explicitly
				for _, disco_item in ipairs(hostapi:get_option_array("disco_items", {})) do
					local other_host = disco_item[1];
					if type(other_host) == "string" then
						local component_module = configmanager.get(other_host, "component_module");
						if component_module then
							table.insert(host_components[component_module], other_host);
						end
					end
				end
			end

			local current_feature;

			local function check_module(suggested, alternate, ...)
				if set.intersection(modules_enabled, set.new({suggested, alternate, ...})):empty() then
					current_feature.lacking_modules = current_feature.lacking_modules or {};
					table.insert(current_feature.lacking_modules, suggested);
				end
			end

			local function check_component(suggested, alternate, ...)
				local found;
				for _, component_module in ipairs({ suggested, alternate, ... }) do
					found = host_components[component_module][1];
					if found then
						local enabled_component_modules = api(found):get_option_inherited_set("modules_enabled");
						local recommended_mods = recommended_component_modules[component_module];
						if recommended_mods then
							local missing_mods = {};
							for _, mod in ipairs(recommended_mods) do
								if not enabled_component_modules:contains(mod) then
									table.insert(missing_mods, mod);
								end
							end
							if #missing_mods > 0 then
								if not current_feature.lacking_component_modules then
									current_feature.lacking_component_modules = {};
								end
								table.insert(current_feature.lacking_component_modules, {
									host = found;
									component_module = component_module;
									missing_mods = missing_mods;
								});
							end
						end
						break;
					end
				end
				if not found then
					current_feature.lacking_components = current_feature.lacking_components or {};
					table.insert(current_feature.lacking_components, suggested);
				end
				return found;
			end

			local features = {
				{
					name = "Basic functionality";
					desc = "Support for secure connections, authentication and messaging";
					check = function ()
						check_module("disco");
						check_module("roster");
						check_module("saslauth");
						check_module("tls");
					end;
				};
				{
					name = "Multi-device messaging and data synchronization";
					desc = "Multiple clients connected to the same account stay in sync";
					check = function ()
						check_module("carbons");
						check_module("mam");
						check_module("bookmarks");
						check_module("pep");
					end;
				};
				{
					name = "Mobile optimizations";
					desc = "Help mobile clients reduce battery and data usage";
					check = function ()
						check_module("smacks");
						check_module("csi_simple", "csi_battery_saver");
					end;
				};
				{
					name = "Web connections";
					desc = "Allow connections from browser-based web clients";
					check = function ()
						check_module("bosh");
						check_module("websocket");
					end;
				};
				{
					name = "User profiles";
					desc = "Enable users to publish profile information";
					check = function ()
						check_module("vcard_legacy", "vcard");
					end;
				};
				{
					name = "Blocking";
					desc = "Block communication with chosen entities";
					check = function ()
						check_module("blocklist");
					end;
				};
				{
					name = "Push notifications";
					desc = "Receive notifications on platforms that don't support persistent connections";
					check = function ()
						check_module("cloud_notify");
					end;
				};
				{
					name = "Audio/video calls and P2P";
					desc = "Assist clients in setting up connections between each other";
					check = function ()
						check_module(
							"turn_external",
							"external_services",
							"turncredentials",
							"extdisco"
						);
					end;
				};
				{
					name = "File sharing";
					desc = "Sharing of files to groups and offline users";
					check = function (self)
						local service = check_component("http_file_share", "http_upload", "http_upload_external");
						if service then
							local size_limit;
							if api(service):get_option("component_module") == "http_file_share" then
								size_limit = api(service):get_option_number("http_file_share_size_limit", 10*1024*1024);
							end
							if size_limit then
								self.meta = {
									["Size limit"] = human_units.format(size_limit, "b", "b");
								};
							end
						end
					end;
				};
				{
					name = "Group chats";
					desc = "Create group chats and channels";
					check = function ()
						check_component("muc");
					end;
				};
			};

			if not quiet then
				print(host);
			end

			for _, feature in ipairs(features) do
				current_feature = feature;
				feature:check();
				feature.ok = (
					not feature.lacking_modules and
					not feature.lacking_components and
					not feature.lacking_component_modules
				);
				-- For improved presentation, we group the (ok) and (not ok) features
				if feature.ok then
					print_feature_status(feature, host);
				end
			end

			for _, feature in ipairs(features) do
				if not feature.ok then
					all_ok = false;
					print_feature_status(feature, host);
				end
			end

			if not quiet then
				print("");
			end
		end

		return all_ok;
	end

	if what == nil or what == "all" then
		local ret;
		ret = checks.disabled();
		if ret ~= nil then return ret; end
		ret = checks.config();
		if ret ~= nil then return ret; end
		ret = checks.dns();
		if ret ~= nil then return ret; end
		ret = checks.certs();
		if ret ~= nil then return ret; end
		ret = checks.turn();
		if ret ~= nil then return ret; end
	elseif checks[what] then
		local ret = checks[what]();
		if ret ~= nil then return ret; end
	else
		show_warning("Don't know how to check '%s'. Try one of 'config', 'dns', 'certs', 'disabled', 'turn' or 'connectivity'.", what);
		show_warning("Note: The connectivity check will connect to a remote server.");
		return 1;
	end

	if not ok then
		print("Problems found, see above.");
	else
		print("All checks passed, congratulations!");
	end
	return ok and 0 or 2;
end

return {
	check = check;
};
