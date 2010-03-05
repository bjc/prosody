local configmanager = require "core.configmanager";
local log = require "util.logger".init("certmanager");
local ssl = ssl;
local ssl_newcontext = ssl and ssl.newcontext;

local setmetatable, tostring = setmetatable, tostring;

local prosody = prosody;

module "certmanager"

-- These are the defaults if not overridden in the config
local default_ssl_ctx = { mode = "client", protocol = "sslv23", capath = "/etc/ssl/certs", verify = "none", options = "no_sslv2"; };
local default_ssl_ctx_in = { mode = "server", protocol = "sslv23", capath = "/etc/ssl/certs", verify = "none", options = "no_sslv2"; };

local default_ssl_ctx_mt = { __index = default_ssl_ctx };
local default_ssl_ctx_in_mt = { __index = default_ssl_ctx_in };

-- Global SSL options if not overridden per-host
local default_ssl_config = configmanager.get("*", "core", "ssl");

function create_context(host, mode, config)
	local ssl_config = config and config.core.ssl or default_ssl_config;
	if ssl and ssl_config then
		local ctx, err = ssl_newcontext(setmetatable(ssl_config, mode == "client" and default_ssl_ctx_mt or default_ssl_ctx_in_mt));
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
			ssl = false
        	end
        	return ctx, err;
	end
	return nil;
end

function reload_ssl_config()
	default_ssl_config = configmanager.get("*", "core", "ssl");
end

prosody.events.add_handler("config-reloaded", reload_ssl_config);

return _M;
