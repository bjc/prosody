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

local setmetatable, tostring = setmetatable, tostring;

local prosody = prosody;
local resolve_path = configmanager.resolve_relative_path;
local config_path = prosody.paths.config;

module "certmanager"

-- Global SSL options if not overridden per-host
local default_ssl_config = configmanager.get("*", "core", "ssl");
local default_capath = "/etc/ssl/certs";

function create_context(host, mode, user_ssl_config)
	user_ssl_config = user_ssl_config or default_ssl_config;

	if not ssl then return nil, "LuaSec (required for encryption) was not found"; end
	if not user_ssl_config then return nil, "No SSL/TLS configuration present for "..host; end
	
	local ssl_config = {
		mode = mode;
		protocol = user_ssl_config.protocol or "sslv23";
		key = resolve_path(config_path, user_ssl_config.key);
		password = user_ssl_config.password;
		certificate = resolve_path(config_path, user_ssl_config.certificate);
		capath = resolve_path(config_path, user_ssl_config.capath or default_capath);
		cafile = resolve_path(config_path, user_ssl_config.cafile);
		verify = user_ssl_config.verify or "none";
		options = user_ssl_config.options or "no_sslv2";
		ciphers = user_ssl_config.ciphers;
		depth = user_ssl_config.depth;
	};

	local ctx, err = ssl_newcontext(ssl_config);
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
			log("error", "SSL/TLS: Failed to load %s: %s", file, reason);
		else
			log("error", "SSL/TLS: Error initialising for host %s: %s", host, err );
		end
	end
	return ctx, err;
end

function reload_ssl_config()
	default_ssl_config = configmanager.get("*", "core", "ssl");
end

prosody.events.add_handler("config-reloaded", reload_ssl_config);

return _M;
