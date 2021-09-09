local configmanager = require "core.configmanager";
local show_usage = require "util.prosodyctl".show_usage;
local show_warning = require "util.prosodyctl".show_warning;
local dependencies = require "util.dependencies";
local socket = require "socket";
local jid_split = require "util.jid".prepped_split;
local modulemanager = require "core.modulemanager";

local function check(arg)
	if arg[1] == "--help" then
		show_usage([[check]], [[Perform basic checks on your Prosody installation]]);
		return 1;
	end
	local what = table.remove(arg, 1);
	local set = require "util.set";
	local it = require "util.iterators";
	local ok = true;
	local function disabled_hosts(host, conf) return host ~= "*" and conf.enabled ~= false; end
	local function enabled_hosts() return it.filter(disabled_hosts, pairs(configmanager.getconfig())); end
	if not (what == nil or what == "disabled" or what == "config" or what == "dns" or what == "certs") then
		show_warning("Don't know how to check '%s'. Try one of 'config', 'dns', 'certs' or 'disabled'.", what);
		return 1;
	end
	if not what or what == "disabled" then
		local disabled_hosts_set = set.new();
		for host, host_options in it.filter("*", pairs(configmanager.getconfig())) do
			if host_options.enabled == false then
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
	if not what or what == "config" then
		print("Checking config...");
		local deprecated = set.new({
			"anonymous_login",
			"bosh_ports",
			"cross_domain_bosh",
			"cross_domain_websocket",
			"daemonize",
			"disallow_s2s",
			"legacy_ssl_interfaces",
			"legacy_ssl_port",
			"legacy_ssl_ports",
			"legacy_ssl_ssl",
			"no_daemonize",
			"require_encryption",
			"vcard_compatibility",
		});
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
			"cross_domain_bosh",
			"cross_domain_websocket",
			"daemonize",
			"gc",
			"http_default_host",
			"http_errors_always_show",
			"http_errors_default_message",
			"http_errors_detailed",
			"http_errors_messages",
			"installer_plugin_path",
			"limits",
			"limits_resolution",
			"log",
			"multiplex_buffer_size",
			"network_backend",
			"network_default_read_size",
			"network_settings",
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
			"trusted_proxies",
			"umask",
			"use_dane",
			"use_ipv4",
			"use_ipv6",
			"use_libevent",
			"websocket_frame_buffer_limit",
			"websocket_frame_fragment_limit",
			"websocket_get_response_body",
			"websocket_get_response_text",
		});
		local config = configmanager.getconfig();
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

		do -- Check for modules enabled both normally and as components
			local modules = set.new(config["*"]["modules_enabled"]);
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
		local deprecated_global_options = set.intersection(global_options, deprecated);
		if not deprecated_global_options:empty() then
			print("");
			print("    You have some deprecated options in the global section:");
			print("    "..tostring(deprecated_global_options))
			ok = false;
			-- FIXME show replacement options where applicable
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
					if config[host].s2s_secure_auth == true then
						secure_domains:add("*");
					else
						secure_domains:include(set.new(config[host].s2s_secure_domains));
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

		print("Done.\n");
	end
	if not what or what == "dns" then
		local dns = require "net.dns";
		pcall(function ()
			local unbound = require"net.unbound";
			local unbound_config = configmanager.get("*", "unbound") or {};
			unbound_config.hoststxt = false; -- don't look at /etc/hosts
			configmanager.set("*", "unbound", unbound_config);
			unbound.purge(); -- ensure the above config is used
			dns = unbound.dns;
		end)
		local idna = require "util.encodings".idna;
		local ip = require "util.ip";
		local c2s_ports = set.new(configmanager.get("*", "c2s_ports") or {5222});
		local s2s_ports = set.new(configmanager.get("*", "s2s_ports") or {5269});
		local c2s_tls_ports = set.new(configmanager.get("*", "direct_tls_ports") or {});
		local s2s_tls_ports = set.new(configmanager.get("*", "s2s_direct_tls_ports") or {});

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
			do
				local res = dns.lookup(idna.to_ascii(fqdn), "A");
				if res then
					for _, record in ipairs(res) do
						external_addresses:add(record.a);
					end
				end
			end
			do
				local res = dns.lookup(idna.to_ascii(fqdn), "AAAA");
				if res then
					for _, record in ipairs(res) do
						external_addresses:add(record.aaaa);
					end
				end
			end
		end

		local local_addresses = require"util.net".local_addresses() or {};

		for addr in it.values(local_addresses) do
			if not ip.new_ip(addr).private then
				external_addresses:add(addr);
			else
				internal_addresses:add(addr);
			end
		end

		if external_addresses:empty() then
			print("");
			print("   Failed to determine the external addresses of this server. Checks may be inaccurate.");
			c2s_srv_required, s2s_srv_required = true, true;
		end

		local v6_supported = not not socket.tcp6;

		local function trim_dns_name(n)
			return (n:gsub("%.$", ""));
		end

		for jid, host_options in enabled_hosts() do
			local all_targets_ok, some_targets_ok = true, false;
			local node, host = jid_split(jid);

			local modules, component_module = modulemanager.get_modules_for_host(host);
			if component_module then
				modules:add(component_module);
			end

			local is_component = not not host_options.component_module;
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
			if modules:contains("c2s") and c2s_tls_srv_required then
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
				else
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
			if modules:contains("s2s") and s2s_tls_srv_required then
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
				else
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

			if modules:contains("proxy65") then
				local proxy65_target = configmanager.get(host, "proxy65_address") or host;
				if type(proxy65_target) == "string" then
					local A, AAAA = dns.lookup(idna.to_ascii(proxy65_target), "A"), dns.lookup(idna.to_ascii(proxy65_target), "AAAA");
					local prob = {};
					if not A then
						table.insert(prob, "A");
					end
					if v6_supported and not AAAA then
						table.insert(prob, "AAAA");
					end
					if #prob > 0 then
						print("    File transfer proxy "..proxy65_target.." has no "..table.concat(prob, "/")
						.." record. Create one or set 'proxy65_address' to the correct host/IP.");
					end
				else
					print("    proxy65_address for "..host.." should be set to a string, unable to perform DNS check");
				end
			end

			local use_ipv4 = configmanager.get("*", "use_ipv4") ~= false;
			local use_ipv6 = configmanager.get("*", "use_ipv6") ~= false;
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
			print("");
			print("For more information about DNS configuration please see https://prosody.im/doc/dns");
			print("");
			ok = false;
		end
	end
	if not what or what == "certs" then
		local cert_ok;
		print"Checking certificates..."
		local x509_verify_identity = require"util.x509".verify_identity;
		local create_context = require "core.certmanager".create_context;
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
			local function skip_bare_jid_hosts(host)
				if jid_split(host) then
					-- See issue #779
					return false;
				end
				return true;
			end
			for host in it.filter(skip_bare_jid_hosts, enabled_hosts()) do
				print("Checking certificate for "..host);
				-- First, let's find out what certificate this host uses.
				local host_ssl_config = configmanager.rawget(host, "ssl")
					or configmanager.rawget(host:match("%.(.*)"), "ssl");
				local global_ssl_config = configmanager.rawget("*", "ssl");
				local ok, err, ssl_config = create_context(host, "server", host_ssl_config, global_ssl_config);
				if not ok then
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
						if configmanager.get(host, "component_module") == nil
							and not x509_verify_identity(host, "_xmpp-client", cert) then
							print("    Not valid for client connections to "..host..".")
							cert_ok = false
						end
						if (not (configmanager.get(host, "anonymous_login")
							or configmanager.get(host, "authentication") == "anonymous"))
							and not x509_verify_identity(host, "_xmpp-server", cert) then
							print("    Not valid for server-to-server connections to "..host..".")
							cert_ok = false
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
