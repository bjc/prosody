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

local tostring = tostring;
local pairs = pairs;
local type = type;
local io_open = io.open;
local select = select;

local prosody = prosody;
local resolve_path = require"util.paths".resolve_relative_path;
local config_path = prosody.paths.config;

local luasec_major, luasec_minor = ssl._VERSION:match("^(%d+)%.(%d+)");
local luasec_version = luasec_major * 100 + luasec_minor;
local luasec_has = {
	-- TODO If LuaSec ever starts exposing these things itself, use that instead
	cipher_server_preference = luasec_version >= 2;
	no_ticket = luasec_version >= 4;
	no_compression = luasec_version >= 5;
	single_dh_use = luasec_version >= 2;
	single_ecdh_use = luasec_version >= 2;
};

module "certmanager"

-- Global SSL options if not overridden per-host
local global_ssl_config = configmanager.get("*", "ssl");

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
	ciphers = "HIGH+kEDH:HIGH+kEECDH:HIGH:!PSK:!SRP:!3DES:!aNULL";
}
local path_options = { -- These we pass through resolve_path()
	key = true, certificate = true, cafile = true, capath = true, dhparam = true
}

if not luasec_has_verifyext and ssl_x509 then
	-- COMPAT mw/luasec-hg
	for i=1,#core_defaults.verifyext do -- Remove lsec_ prefix
		core_defaults.verify[#core_defaults.verify+1] = core_defaults.verifyext[i]:sub(6);
	end
end

function create_context(host, mode, ...)
	local cfg = new_config();
	cfg:apply(core_defaults);
	cfg:apply(global_ssl_config);
	cfg:apply({
		mode = mode,
		-- We can't read the password interactively when daemonized
		password = function() log("error", "Encrypted certificate for %s requires 'ssl' 'password' to be set in config", host); end;
	});

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
			if file == "private key" then
				file = user_ssl_config.key or "your private key";
			elseif file == "certificate" then
				file = user_ssl_config.certificate or "your certificate file";
			end
			local reason = err:match("%((.+)%)$") or "some reason";
			if reason == "Permission denied" then
				reason = "Check that the permissions allow Prosody to read this file.";
			elseif reason == "No such file or directory" then
				reason = "Check that the path is correct, and the file exists.";
			elseif reason == "system lib" then
				reason = "Previous error (see logs), or other system error.";
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

function reload_ssl_config()
	global_ssl_config = configmanager.get("*", "ssl");
	if luasec_has.no_compression then
		core_defaults.options.no_compression = configmanager.get("*", "ssl_compression") ~= true;
	end
end

prosody.events.add_handler("config-reloaded", reload_ssl_config);

return _M;
