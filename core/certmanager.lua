-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local configmanager = require "prosody.core.configmanager";
local log = require "prosody.util.logger".init("certmanager");
local new_config = require"prosody.net.server".tls_builder;
local tls = require "prosody.net.tls_luasec";
local stat = require "lfs".attributes;

local x509 = require "prosody.util.x509";
local lfs = require "lfs";

local tonumber, tostring = tonumber, tostring;
local pairs = pairs;
local t_remove = table.remove;
local type = type;
local io_open = io.open;
local select = select;
local now = os.time;
local next = next;
local pcall = pcall;

local prosody = prosody;
local pathutil = require"prosody.util.paths";
local resolve_path = pathutil.resolve_relative_path;
local config_path = prosody.paths.config or ".";

local _ENV = nil;
-- luacheck: std none

-- Global SSL options if not overridden per-host
local global_ssl_config = configmanager.get("*", "ssl");

local global_certificates = configmanager.get("*", "certificates") or "certs";

local crt_try = { "", "/%s.crt", "/%s/fullchain.pem", "/%s.pem", };
local key_try = { "", "/%s.key", "/%s/privkey.pem",   "/%s.pem", };

local function find_cert(user_certs, name)
	local certs = resolve_path(config_path, user_certs or global_certificates);
	log("debug", "Searching %s for a key and certificate for %s...", certs, name);
	for i = 1, #crt_try do
		local crt_path = certs .. crt_try[i]:format(name);
		local key_path = certs .. key_try[i]:format(name);

		if stat(crt_path, "mode") == "file" then
			if crt_path == key_path then
				if key_path:sub(-4) == ".crt" then
					key_path = key_path:sub(1, -4) .. "key";
				elseif key_path:sub(-14) == "/fullchain.pem" then
					key_path = key_path:sub(1, -14) .. "privkey.pem";
				end
			end

			if stat(key_path, "mode") == "file" then
				log("debug", "Selecting certificate %s with key %s for %s", crt_path, key_path, name);
				return { certificate = crt_path, key = key_path };
			end
		end
	end
	log("debug", "No certificate/key found for %s", name);
end

local function find_matching_key(cert_path)
	return (cert_path:gsub("%.crt$", ".key"):gsub("fullchain", "privkey"));
end

local function index_certs(dir, files_by_name, depth_limit)
	files_by_name = files_by_name or {};
	depth_limit = depth_limit or 3;
	if depth_limit <= 0 then return files_by_name; end

	local ok, iter, v, i = pcall(lfs.dir, dir);
	if not ok then
		log("error", "Error indexing certificate directory %s: %s", dir, iter);
		-- Return an empty index, otherwise this just triggers a nil indexing
		-- error, plus this function would get called again.
		-- Reloading the config after correcting the problem calls this again so
		-- that's what should be done.
		return {}, iter;
	end
	for file in iter, v, i do
		local full = pathutil.join(dir, file);
		if lfs.attributes(full, "mode") == "directory" then
			if file:sub(1,1) ~= "." then
				index_certs(full, files_by_name, depth_limit-1);
			end
		elseif file:find("%.crt$") or file:find("fullchain") then -- This should catch most fullchain files
			local f, err = io_open(full);
			if f then
				-- TODO look for chained certificates
				local firstline = f:read();
				if firstline == "-----BEGIN CERTIFICATE-----" and lfs.attributes(find_matching_key(full), "mode") == "file" then
					f:seek("set")
					local cert = tls.load_certificate(f:read("*a"))
					-- TODO if more than one cert is found for a name, the most recently
					-- issued one should be used.
					-- for now, just filter out expired certs
					-- TODO also check if there's a corresponding key
					if cert:validat(now()) then
						local names = x509.get_identities(cert);
						log("debug", "Found certificate %s with identities %q", full, names);
						for name, services in pairs(names) do
							-- TODO check services
							if files_by_name[name] then
								files_by_name[name][full] = services;
							else
								files_by_name[name] = { [full] = services; };
							end
						end
					else
						log("debug", "Skipping expired certificate: %s", full);
					end
				else
					log("debug", "Skipping non-certificate (based on contents): %s", full);
				end
				f:close();
			elseif err then
				log("debug", "Skipping file due to error:  %s", err);
			end
		else
			log("debug", "Skipping non-certificate (based on filename): %s", full);
		end
	end
	-- | hostname | filename | service |
	return files_by_name;
end

local cert_index;

local function find_cert_in_index(index, host)
	if not host then return nil; end
	if not index then return nil; end
	local wildcard_host = host:gsub("^[^.]+%.", "*.");
	local certs = index[host] or index[wildcard_host];
	if certs then
		local cert_filename, services = next(certs);
		if services["*"] then
			log("debug", "Using cert %q from index for host %q", cert_filename, host);
			return {
				certificate = cert_filename,
				key = find_matching_key(cert_filename),
			}
		end
	end
	return nil
end

local function find_host_cert(host)
	if not host then return nil; end
	if not cert_index then
		cert_index = index_certs(resolve_path(config_path, global_certificates));
	end

	return find_cert_in_index(cert_index, host) or find_cert(configmanager.get(host, "certificate"), host) or find_host_cert(host:match("%.(.+)$"));
end

local function find_service_cert(service, port)
	if not cert_index then
		cert_index = index_certs(resolve_path(config_path, global_certificates));
	end
	for _, certs in pairs(cert_index) do
		for cert_filename, services in pairs(certs) do
			if services[service] or services["*"] then
				log("debug", "Using cert %q from index for service %s port %d", cert_filename, service, port);
				return {
					certificate = cert_filename,
					key = find_matching_key(cert_filename),
				}
			end
		end
	end
	local cert_config = configmanager.get("*", service.."_certificate");
	if type(cert_config) == "table" then
		cert_config = cert_config[port] or cert_config.default;
	end
	return find_cert(cert_config, service);
end

-- Built-in defaults
local core_defaults = {
	capath = "/etc/ssl/certs";
	depth = 9;
	protocol = "tlsv1+";
	verify = "none";
	options = {
		cipher_server_preference = tls.features.options.cipher_server_preference;
		no_ticket = tls.features.options.no_ticket;
		no_compression = tls.features.options.no_compression and configmanager.get("*", "ssl_compression") ~= true;
		single_dh_use = tls.features.options.single_dh_use;
		single_ecdh_use = tls.features.options.single_ecdh_use;
		no_renegotiation = tls.features.options.no_renegotiation;
	};
	curve = tls.features.algorithms.ec and not tls.features.capabilities.curves_list and "secp384r1";
	curveslist = {
		"X25519",
		"P-384",
		"P-256",
		"P-521",
	};
	ciphers = {      -- Enabled ciphers in order of preference:
		"HIGH+kEECDH", -- Ephemeral Elliptic curve Diffie-Hellman key exchange
		"HIGH+kEDH",   -- Ephemeral Diffie-Hellman key exchange, if a 'dhparam' file is set
		"HIGH",        -- Other "High strength" ciphers
		               -- Disabled cipher suites:
		"!PSK",        -- Pre-Shared Key - not used for XMPP
		"!SRP",        -- Secure Remote Password - not used for XMPP
		"!3DES",       -- 3DES - slow and of questionable security
		"!aNULL",      -- Ciphers that does not authenticate the connection
	};
	dane = tls.features.capabilities.dane and configmanager.get("*", "use_dane") and { "no_ee_namechecks" };
}

-- https://datatracker.ietf.org/doc/html/rfc7919#appendix-A.1
local ffdhe2048 = [[
-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----
]]

local mozilla_ssl_configs = {
	-- https://wiki.mozilla.org/Security/Server_Side_TLS
	-- Version 5.7 as of 2023-07-09
	modern = {
		protocol = "tlsv1_3";
		options = { cipher_server_preference = false };
		ciphers = "DEFAULT"; -- TLS 1.3 uses 'ciphersuites' rather than these
		curveslist = { "X25519"; "prime256v1"; "secp384r1" };
		ciphersuites = { "TLS_AES_128_GCM_SHA256"; "TLS_AES_256_GCM_SHA384"; "TLS_CHACHA20_POLY1305_SHA256" };
	};
	intermediate = {
		protocol = "tlsv1_2+";
		dhparam = ffdhe2048;
		options = { cipher_server_preference = false };
		ciphers = {
			"ECDHE-ECDSA-AES128-GCM-SHA256";
			"ECDHE-RSA-AES128-GCM-SHA256";
			"ECDHE-ECDSA-AES256-GCM-SHA384";
			"ECDHE-RSA-AES256-GCM-SHA384";
			"ECDHE-ECDSA-CHACHA20-POLY1305";
			"ECDHE-RSA-CHACHA20-POLY1305";
			"DHE-RSA-AES128-GCM-SHA256";
			"DHE-RSA-AES256-GCM-SHA384";
			"DHE-RSA-CHACHA20-POLY1305";
		};
		curveslist = { "X25519"; "prime256v1"; "secp384r1" };
		ciphersuites = { "TLS_AES_128_GCM_SHA256"; "TLS_AES_256_GCM_SHA384"; "TLS_CHACHA20_POLY1305_SHA256" };
	};
	old = {
		protocol = "tlsv1+";
		dhparam = nil; -- openssl dhparam 1024
		options = { cipher_server_preference = true };
		ciphers = {
			"ECDHE-ECDSA-AES128-GCM-SHA256";
			"ECDHE-RSA-AES128-GCM-SHA256";
			"ECDHE-ECDSA-AES256-GCM-SHA384";
			"ECDHE-RSA-AES256-GCM-SHA384";
			"ECDHE-ECDSA-CHACHA20-POLY1305";
			"ECDHE-RSA-CHACHA20-POLY1305";
			"DHE-RSA-AES128-GCM-SHA256";
			"DHE-RSA-AES256-GCM-SHA384";
			"DHE-RSA-CHACHA20-POLY1305";
			"ECDHE-ECDSA-AES128-SHA256";
			"ECDHE-RSA-AES128-SHA256";
			"ECDHE-ECDSA-AES128-SHA";
			"ECDHE-RSA-AES128-SHA";
			"ECDHE-ECDSA-AES256-SHA384";
			"ECDHE-RSA-AES256-SHA384";
			"ECDHE-ECDSA-AES256-SHA";
			"ECDHE-RSA-AES256-SHA";
			"DHE-RSA-AES128-SHA256";
			"DHE-RSA-AES256-SHA256";
			"AES128-GCM-SHA256";
			"AES256-GCM-SHA384";
			"AES128-SHA256";
			"AES256-SHA256";
			"AES128-SHA";
			"AES256-SHA";
			"DES-CBC3-SHA";
		};
		curveslist = { "X25519"; "prime256v1"; "secp384r1" };
		ciphersuites = { "TLS_AES_128_GCM_SHA256"; "TLS_AES_256_GCM_SHA384"; "TLS_CHACHA20_POLY1305_SHA256" };
	};
};


if tls.features.curves then
	for i = #core_defaults.curveslist, 1, -1 do
		if not tls.features.curves[ core_defaults.curveslist[i] ] then
			t_remove(core_defaults.curveslist, i);
		end
	end
else
	core_defaults.curveslist = nil;
end

local function create_context(host, mode, ...)
	local cfg = new_config();
	cfg:apply(core_defaults);
	local service_name, port = host:match("^(%S+) port (%d+)$");
	-- port 0 is used with client-only things that normally don't need certificates, e.g. https
	if service_name and port ~= "0" then
		log("debug", "Automatically locating certs for service %s on port %s", service_name, port);
		cfg:apply(find_service_cert(service_name, tonumber(port)));
	else
		log("debug", "Automatically locating certs for host %s", host);
		cfg:apply(find_host_cert(host));
	end
	cfg:apply({
		mode = mode,
		-- We can't read the password interactively when daemonized
		password = function() log("error", "Encrypted certificate for %s requires 'ssl' 'password' to be set in config", host); end;
	});
	local profile = configmanager.get("*", "tls_profile") or "intermediate";
	if mozilla_ssl_configs[profile] then
		cfg:apply(mozilla_ssl_configs[profile]);
	elseif profile ~= "legacy" then
		log("error", "Invalid value for 'tls_profile': expected one of \"modern\", \"intermediate\" (default), \"old\" or \"legacy\" but got %q", profile);
		return nil, "Invalid configuration, 'tls_profile' had an unknown value.";
	end
	cfg:apply(global_ssl_config);

	for i = select('#', ...), 1, -1 do
		cfg:apply(select(i, ...));
	end
	local user_ssl_config = cfg:final();

	if mode == "server" then
		if not user_ssl_config.certificate then
			log("debug", "No certificate present in SSL/TLS configuration for %s. SNI will be required.", host);
		end
		if user_ssl_config.certificate and not user_ssl_config.key then return nil, "No key present in SSL/TLS configuration for "..host; end
	end

	local ctx, err = cfg:build();

	if not ctx then
		err = err or "invalid ssl config"
		local file = err:match("^error loading (.-) %(");
		if file then
			local typ;
			if file == "private key" then
				typ = file;
				file = user_ssl_config.key or "your private key";
			elseif file == "certificate" then
				typ = file;
				file = user_ssl_config.certificate or "your certificate file";
			end
			local reason = err:match("%((.+)%)$") or "some reason";
			if reason == "Permission denied" then
				reason = "Check that the permissions allow Prosody to read this file.";
			elseif reason == "No such file or directory" then
				reason = "Check that the path is correct, and the file exists.";
			elseif reason == "system lib" then
				reason = "Previous error (see logs), or other system error.";
			elseif reason == "no start line" then
				reason = "Check that the file contains a "..(typ or file);
			elseif reason == "(null)" or not reason then
				reason = "Check that the file exists and the permissions are correct";
			else
				reason = "Reason: "..tostring(reason):lower();
			end
			log("error", "SSL/TLS: Failed to load '%s': %s (for %s)", file, reason, host);
		else
			log("error", "SSL/TLS: Error initialising for %s: %s", host, err);
		end
	end
	return ctx, err, user_ssl_config;
end

local function reload_ssl_config()
	global_ssl_config = configmanager.get("*", "ssl");
	global_certificates = configmanager.get("*", "certificates") or "certs";
	if tls.features.options.no_compression then
		core_defaults.options.no_compression = configmanager.get("*", "ssl_compression") ~= true;
	end
	if not configmanager.get("*", "use_dane") then
		core_defaults.dane = false;
	elseif tls.features.capabilities.dane then
		core_defaults.dane = { "no_ee_namechecks" };
	else
		core_defaults.dane = true;
	end
	cert_index = index_certs(resolve_path(config_path, global_certificates));
end

prosody.events.add_handler("config-reloaded", reload_ssl_config);

return {
	create_context = create_context;
	reload_ssl_config = reload_ssl_config;
	find_cert = find_cert;
	index_certs = index_certs;
	find_host_cert = find_host_cert;
	find_cert_in_index = find_cert_in_index;
};
