
hosts = {};

local hosts = hosts;
local configmanager = require "core.configmanager";
local eventmanager = require "core.eventmanager";

local pairs = pairs;

module "hostmanager"

local function load_enabled_hosts(config)
	local defined_hosts = config or configmanager.getconfig();
	
	for host, host_config in pairs(defined_hosts) do
		if host ~= "*" and (host_config.core.enabled == nil or host_config.core.enabled) then
			activate(host, host_config);
		end
	end
end

eventmanager.add_event_hook("server-starting", load_enabled_hosts);

function activate(host, host_config)
	hosts[host] = {type = "local", connected = true, sessions = {}, host = host, s2sout = {} };
	
	eventmanager.fire_event("host-activated", host, host_config);
end

function deactivate(host)
	local host_session = hosts[host];
	
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
end

function getconfig(name)
end

