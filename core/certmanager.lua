local configmanager = require "core.configmanager";
local ssl = ssl;
local ssl_newcontext = ssl.newcontext;

local setmetatable = setmetatable;

local prosody = prosody;

module "certmanager"

-- These are the defaults if not overridden in the config
local default_ssl_ctx = { mode = "client", protocol = "sslv23", capath = "/etc/ssl/certs", verify = "none", options = "no_sslv2"; };
local default_ssl_ctx_in = { mode = "server", protocol = "sslv23", capath = "/etc/ssl/certs", verify = "none", options = "no_sslv2"; };

local default_ssl_ctx_mt = { __index = default_ssl_ctx };
local default_ssl_ctx_in_mt = { __index = default_ssl_ctx_in };

-- Global SSL options if not overridden per-host
local default_ssl_config = configmanager.get("*", "core", "ssl");

function get_context(host, mode, config)
	local ssl_config = config and config.core.ssl or default_ssl_config;
	if ssl and ssl_config then
		return ssl_newcontext(setmetatable(ssl_config, mode == "client" and default_ssl_ctx_mt or default_ssl_ctx_in_mt));
	end
	return nil;
end

function reload_ssl_config()
	default_ssl_config = config.get("*", "core", "ssl");
end

prosody.events.add_handler("config-reloaded", reload_ssl_config);

return _M;
