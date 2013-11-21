-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local configmanager = require "core.configmanager";
local log = require "util.logger".init("certmanager");
local ssl = ssl;
local ssl_newcontext = ssl and ssl.newcontext;

local tostring = tostring;
local type = type;
local io_open = io.open;

local prosody = prosody;
local resolve_path = configmanager.resolve_relative_path;
local config_path = prosody.paths.config;

local luasec_has_noticket, luasec_has_verifyext, luasec_has_no_compression;
if ssl then
	local luasec_major, luasec_minor = ssl._VERSION:match("^(%d+)%.(%d+)");
	luasec_has_noticket = tonumber(luasec_major)>0 or tonumber(luasec_minor)>=4;
	luasec_has_verifyext = tonumber(luasec_major)>0 or tonumber(luasec_minor)>=5;
	luasec_has_no_compression = tonumber(luasec_major)>0 or tonumber(luasec_minor)>=5;
end

module "certmanager"

-- Global SSL options if not overridden per-host
local default_ssl_config = configmanager.get("*", "ssl");
local default_capath = "/etc/ssl/certs";
local default_verify = (ssl and ssl.x509 and { "peer", "client_once", }) or "none";
local default_options = { "no_sslv2", "cipher_server_preference", luasec_has_noticket and "no_ticket" or nil };
local default_verifyext = { "lsec_continue", "lsec_ignore_purpose" };

if ssl and not luasec_has_verifyext and ssl.x509 then
	-- COMPAT mw/luasec-hg
	for i=1,#default_verifyext do -- Remove lsec_ prefix
		default_verify[#default_verify+1] = default_verifyext[i]:sub(6);
	end
end
if luasec_has_no_compression and configmanager.get("*", "ssl_compression") ~= true then
	default_options[#default_options+1] = "no_compression";
end

if luasec_has_no_compression then -- Has no_compression? Then it has these too...
	default_options[#default_options+1] = "single_dh_use";
	default_options[#default_options+1] = "single_ecdh_use";
end

function create_context(host, mode, user_ssl_config)
	user_ssl_config = user_ssl_config or default_ssl_config;

	if not ssl then return nil, "LuaSec (required for encryption) was not found"; end
	if not user_ssl_config then return nil, "No SSL/TLS configuration present for "..host; end
	
	local ssl_config = {
		mode = mode;
		protocol = user_ssl_config.protocol or "sslv23";
		key = resolve_path(config_path, user_ssl_config.key);
		password = user_ssl_config.password or function() log("error", "Encrypted certificate for %s requires 'ssl' 'password' to be set in config", host); end;
		certificate = resolve_path(config_path, user_ssl_config.certificate);
		capath = resolve_path(config_path, user_ssl_config.capath or default_capath);
		cafile = resolve_path(config_path, user_ssl_config.cafile);
		verify = user_ssl_config.verify or default_verify;
		verifyext = user_ssl_config.verifyext or default_verifyext;
		options = user_ssl_config.options or default_options;
		depth = user_ssl_config.depth;
		curve = user_ssl_config.curve or "secp384r1";
		ciphers = user_ssl_config.ciphers or "HIGH+kEDH:HIGH+kEECDH:HIGH:!PSK:!SRP:!3DES:!aNULL";
		dhparam = user_ssl_config.dhparam;
	};

	-- LuaSec expects dhparam to be a callback that takes two arguments.
	-- We ignore those because it is mostly used for having a separate
	-- set of params for EXPORT ciphers, which we don't have by default.
	if type(ssl_config.dhparam) == "string" then
		local f, err = io_open(resolve_path(config_path, ssl_config.dhparam));
		if not f then return nil, "Could not open DH parameters: "..err end
		local dhparam = f:read("*a");
		f:close();
		ssl_config.dhparam = function() return dhparam; end
	end

	local ctx, err = ssl_newcontext(ssl_config);

	-- COMPAT: LuaSec 0.4.1 ignores the cipher list from the config, so we have to take
	-- care of it ourselves...
	if ctx and ssl_config.ciphers then
		local success;
		success, err = ssl.context.setcipher(ctx, ssl_config.ciphers);
		if not success then ctx = nil; end
	end

	if not ctx then
		err = err or "invalid ssl config"
		local file = err:match("^error loading (.-) %(");
		if file then
			if file == "private key" then
				file = ssl_config.key or "your private key";
			elseif file == "certificate" then
				file = ssl_config.certificate or "your certificate file";
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
	return ctx, err;
end

function reload_ssl_config()
	default_ssl_config = configmanager.get("*", "ssl");
end

prosody.events.add_handler("config-reloaded", reload_ssl_config);

return _M;
