-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local softreq = require"util.dependencies".softreq;
local ssl = softreq"ssl";
if not ssl then
	return {
		create_context = function ()
			return nil, "LuaSec (required for encryption) was not found";
		end;
		reload_ssl_config = function () end;
	}
end

local configmanager = require "core.configmanager";
local log = require "util.logger".init("certmanager");
local ssl_context = ssl.context or softreq"ssl.context";
local ssl_x509 = ssl.x509 or softreq"ssl.x509";
local ssl_newcontext = ssl.newcontext;
local new_config = require"util.sslconfig".new;
local stat = require "lfs".attributes;

local tonumber, tostring = tonumber, tostring;
local pairs = pairs;
local type = type;
local io_open = io.open;
local select = select;

local prosody = prosody;
local resolve_path = require"util.paths".resolve_relative_path;
local config_path = prosody.paths.config or ".";

local luasec_major, luasec_minor = ssl._VERSION:match("^(%d+)%.(%d+)");
local luasec_version = tonumber(luasec_major) * 100 + tonumber(luasec_minor);
local luasec_has = {
	-- TODO If LuaSec ever starts exposing these things itself, use that instead
	cipher_server_preference = luasec_version >= 2;
	no_ticket = luasec_version >= 4;
	no_compression = luasec_version >= 5;
	single_dh_use = luasec_version >= 2;
	single_ecdh_use = luasec_version >= 2;
};

local _ENV = nil;

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
			if key_path:sub(-4) == ".crt" then
				key_path = key_path:sub(1, -4) .. "key";
				if stat(key_path, "mode") == "file" then
					log("debug", "Selecting certificate %s with key %s for %s", crt_path, key_path, name);
					return { certificate = crt_path, key = key_path };
				end
			elseif stat(key_path, "mode") == "file" then
				log("debug", "Selecting certificate %s with key %s for %s", crt_path, key_path, name);
				return { certificate = crt_path, key = key_path };
			end
		end
	end
	log("debug", "No certificate/key found for %s", name);
end

local function find_host_cert(host)
	if not host then return nil; end
	return find_cert(configmanager.get(host, "certificate"), host) or find_host_cert(host:match("%.(.+)$"));
end

local function find_service_cert(service, port)
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
	verify = (ssl_x509 and { "peer", "client_once", }) or "none";
	options = {
		cipher_server_preference = luasec_has.cipher_server_preference;
		no_ticket = luasec_has.no_ticket;
		no_compression = luasec_has.no_compression and configmanager.get("*", "ssl_compression") ~= true;
		single_dh_use = luasec_has.single_dh_use;
		single_ecdh_use = luasec_has.single_ecdh_use;
	};
	verifyext = { "lsec_continue", "lsec_ignore_purpose" };
	curve = "secp384r1";
	ciphers = {      -- Enabled ciphers in order of preference:
		"HIGH+kEDH",   -- Ephemeral Diffie-Hellman key exchange, if a 'dhparam' file is set
		"HIGH+kEECDH", -- Ephemeral Elliptic curve Diffie-Hellman key exchange
		"HIGH",        -- Other "High strength" ciphers
		               -- Disabled cipher suites:
		"!PSK",        -- Pre-Shared Key - not used for XMPP
		"!SRP",        -- Secure Remote Password - not used for XMPP
		"!3DES",       -- 3DES - slow and of questionable security
		"!aNULL",      -- Ciphers that does not authenticate the connection
	};
}
local path_options = { -- These we pass through resolve_path()
	key = true, certificate = true, cafile = true, capath = true, dhparam = true
}

if luasec_version < 5 and ssl_x509 then
	-- COMPAT mw/luasec-hg
	for i=1,#core_defaults.verifyext do -- Remove lsec_ prefix
		core_defaults.verify[#core_defaults.verify+1] = core_defaults.verifyext[i]:sub(6);
	end
end

local function create_context(host, mode, ...)
	local cfg = new_config();
	cfg:apply(core_defaults);
	local service_name, port = host:match("^(%w+) port (%d+)$");
	if service_name then
		cfg:apply(find_service_cert(service_name, tonumber(port)));
	else
		cfg:apply(find_host_cert(host));
	end
	cfg:apply({
		mode = mode,
		-- We can't read the password interactively when daemonized
		password = function() log("error", "Encrypted certificate for %s requires 'ssl' 'password' to be set in config", host); end;
	});
	cfg:apply(global_ssl_config);

	for i = select('#', ...), 1, -1 do
		cfg:apply(select(i, ...));
	end
	local user_ssl_config = cfg:final();

	if mode == "server" then
		if not user_ssl_config.key then return nil, "No key present in SSL/TLS configuration for "..host; end
		if not user_ssl_config.certificate then return nil, "No certificate present in SSL/TLS configuration for "..host; end
	end

	for option in pairs(path_options) do
		if type(user_ssl_config[option]) == "string" then
			user_ssl_config[option] = resolve_path(config_path, user_ssl_config[option]);
		else
			user_ssl_config[option] = nil;
		end
	end

	-- LuaSec expects dhparam to be a callback that takes two arguments.
	-- We ignore those because it is mostly used for having a separate
	-- set of params for EXPORT ciphers, which we don't have by default.
	if type(user_ssl_config.dhparam) == "string" then
		local f, err = io_open(user_ssl_config.dhparam);
		if not f then return nil, "Could not open DH parameters: "..err end
		local dhparam = f:read("*a");
		f:close();
		user_ssl_config.dhparam = function() return dhparam; end
	end

	local ctx, err = ssl_newcontext(user_ssl_config);

	-- COMPAT Older LuaSec ignores the cipher list from the config, so we have to take care
	-- of it ourselves (W/A for #x)
	if ctx and user_ssl_config.ciphers then
		local success;
		success, err = ssl_context.setcipher(ctx, user_ssl_config.ciphers);
		if not success then ctx = nil; end
	end

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
	if luasec_has.no_compression then
		core_defaults.options.no_compression = configmanager.get("*", "ssl_compression") ~= true;
	end
end

prosody.events.add_handler("config-reloaded", reload_ssl_config);

return {
	create_context = create_context;
	reload_ssl_config = reload_ssl_config;
};
