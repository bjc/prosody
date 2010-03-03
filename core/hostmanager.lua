-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local ssl = ssl

local hosts = hosts;
local configmanager = require "core.configmanager";
local eventmanager = require "core.eventmanager";
local modulemanager = require "core.modulemanager";
local events_new = require "util.events".new;

if not _G.prosody.incoming_s2s then
	require "core.s2smanager";
end
local incoming_s2s = _G.prosody.incoming_s2s;

-- These are the defaults if not overridden in the config
local default_ssl_ctx = { mode = "client", protocol = "sslv23", capath = "/etc/ssl/certs", verify = "none", options = "no_sslv2"; };
local default_ssl_ctx_in = { mode = "server", protocol = "sslv23", capath = "/etc/ssl/certs", verify = "none", options = "no_sslv2"; };

local log = require "util.logger".init("hostmanager");

local pairs, setmetatable = pairs, setmetatable;

module "hostmanager"

local hosts_loaded_once;

local function load_enabled_hosts(config)
	local defined_hosts = config or configmanager.getconfig();
	local activated_any_host;
	
	for host, host_config in pairs(defined_hosts) do
		if host ~= "*" and (host_config.core.enabled == nil or host_config.core.enabled) and not host_config.core.component_module then
			activated_any_host = true;
			activate(host, host_config);
		end
	end
	
	if not activated_any_host then
		log("error", "No hosts defined in the config file. This may cause unexpected behaviour as no modules will be loaded.");
	end
	
	eventmanager.fire_event("hosts-activated", defined_hosts);
	hosts_loaded_once = true;
end

eventmanager.add_event_hook("server-starting", load_enabled_hosts);

function activate(host, host_config)
	hosts[host] = {type = "local", connected = true, sessions = {}, 
	               host = host, s2sout = {}, events = events_new(), 
	               disallow_s2s = configmanager.get(host, "core", "disallow_s2s") 
	                 or (configmanager.get(host, "core", "anonymous_login") 
	                     and (configmanager.get(host, "core", "disallow_s2s") ~= false))
	              };
	for option_name in pairs(host_config.core) do
		if option_name:match("_ports$") then
			log("warn", "%s: Option '%s' has no effect for virtual hosts - put it in global Host \"*\" instead", host, option_name);
		end
	end
	
	if ssl then
		local ssl_config = host_config.core.ssl or configmanager.get("*", "core", "ssl");
		if ssl_config then
        		hosts[host].ssl_ctx = ssl.newcontext(setmetatable(ssl_config, { __index = default_ssl_ctx }));
        		hosts[host].ssl_ctx_in = ssl.newcontext(setmetatable(ssl_config, { __index = default_ssl_ctx_in }));
        	end
        end

	log((hosts_loaded_once and "info") or "debug", "Activated host: %s", host);
	eventmanager.fire_event("host-activated", host, host_config);
end

function deactivate(host, reason)
	local host_session = hosts[host];
	log("info", "Deactivating host: %s", host);
	eventmanager.fire_event("host-deactivating", host, host_session);
	
	reason = reason or { condition = "host-gone", text = "This server has stopped serving "..host };
	
	-- Disconnect local users, s2s connections
	if host_session.sessions then
		for username, user in pairs(host_session.sessions) do
			for resource, session in pairs(user.sessions) do
				log("debug", "Closing connection for %s@%s/%s", username, host, resource);
				session:close(reason);
			end
		end
	end
	if host_session.s2sout then
		for remotehost, session in pairs(host_session.s2sout) do
			if session.close then
				log("debug", "Closing outgoing connection to %s", remotehost);
				if session.srv_hosts then session.srv_hosts = nil; end
				session:close(reason);
			end
		end
	end
	for remote_session in pairs(incoming_s2s) do
		if remote_session.to_host == host then
			log("debug", "Closing incoming connection from %s", remote_session.from_host or "<unknown>");
			remote_session:close(reason);
		end
	end

	if host_session.modules then
		for module in pairs(host_session.modules) do
			modulemanager.unload(host, module);
		end
	end

	hosts[host] = nil;
	eventmanager.fire_event("host-deactivated", host);
	log("info", "Deactivated host: %s", host);
end

function getconfig(name)
end

return _M;
