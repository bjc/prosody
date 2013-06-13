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
local pairs = pairs;

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
local global_ssl_config = configmanager.get("*", "ssl");

local core_defaults = {
	capath = "/etc/ssl/certs";
	protocol = "sslv23";
	verify = (ssl and ssl.x509 and { "peer", "client_once", }) or "none";
	options = { "no_sslv2", luasec_has_noticket and "no_ticket" or nil };
	verifyext = { "lsec_continue", "lsec_ignore_purpose" };
	curve = "secp384r1";
}
local path_options = { -- These we pass through resolve_path()
	key = true, certificate = true, cafile = true, capath = true
}

if ssl and not luasec_has_verifyext and ssl.x509 then
	-- COMPAT mw/luasec-hg
	for i=1,#core_defaults.verifyext do -- Remove lsec_ prefix
		core_defaults.verify[#core_defaults.verify+1] = core_defaults.verifyext[i]:sub(6);
	end
end

if luasec_has_no_compression and configmanager.get("*", "ssl_compression") ~= true then
	core_defaults.options[#core_defaults.options+1] = "no_compression";
end

function create_context(host, mode, user_ssl_config)
	user_ssl_config = user_ssl_config or {}
	user_ssl_config.mode = mode;

	if not ssl then return nil, "LuaSec (required for encryption) was not found"; end

	if global_ssl_config then
		for option,default_value in pairs(global_ssl_config) do
			if not user_ssl_config[option] then
				user_ssl_config[option] = default_value;
			end
		end
	end
	for option,default_value in pairs(core_defaults) do
		if not user_ssl_config[option] then
			user_ssl_config[option] = default_value;
		end
	end
	user_ssl_config.password = user_ssl_config.password or function() log("error", "Encrypted certificate for %s requires 'ssl' 'password' to be set in config", host); end;
	for option in pairs(path_options) do
		user_ssl_config[option] = user_ssl_config[option] and resolve_path(config_path, user_ssl_config[option]);
	end

	if not user_ssl_config.key then return nil, "No key present in SSL/TLS configuration for "..host; end
	if not user_ssl_config.certificate then return nil, "No certificate present in SSL/TLS configuration for "..host; end

	local ctx, err = ssl_newcontext(user_ssl_config);

	-- COMPAT Older LuaSec ignores the cipher list from the config, so we have to take care
	-- of it ourselves (W/A for #x)
	if ctx and user_ssl_config.ciphers then
		local success;
		success, err = ssl.context.setcipher(ctx, user_ssl_config.ciphers);
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
	return ctx, err;
end

function reload_ssl_config()
	global_ssl_config = configmanager.get("*", "ssl");
end

prosody.events.add_handler("config-reloaded", reload_ssl_config);

return _M;
