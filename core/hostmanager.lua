
local hosts = hosts;
local configmanager = require "core.configmanager";
local eventmanager = require "core.eventmanager";
local events_new = require "util.events".new;

local log = require "util.logger".init("hostmanager");

local pairs = pairs;

module "hostmanager"

local hosts_loaded_once;

local function load_enabled_hosts(config)
	local defined_hosts = config or configmanager.getconfig();
	
	for host, host_config in pairs(defined_hosts) do
		if host ~= "*" and (host_config.core.enabled == nil or host_config.core.enabled) then
			activate(host, host_config);
		end
	end
	eventmanager.fire_event("hosts-activated", defined_hosts);
	hosts_loaded_once = true;
end

eventmanager.add_event_hook("server-starting", load_enabled_hosts);

function activate(host, host_config)
	hosts[host] = {type = "local", connected = true, sessions = {}, host = host, s2sout = {}, events = events_new() };
	log((hosts_loaded_once and "info") or "debug", "Activated host: %s", host);
	eventmanager.fire_event("host-activated", host, host_config);
end

function deactivate(host)
	local host_session = hosts[host];
	log("info", "Deactivating host: %s", host);
	eventmanager.fire_event("host-deactivating", host, host_session);
	
	-- Disconnect local users, s2s connections
	for user, session_list in pairs(host_session.sessions) do
		for resource, session in pairs(session_list) do
			session:close("host-gone");
		end
	end
	-- Components?
	
	hosts[host] = nil;
	eventmanager.fire_event("host-deactivated", host);
	log("info", "Deactivated host: %s", host);
end

function getconfig(name)
end

