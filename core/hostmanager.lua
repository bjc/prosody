-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local configmanager = require "prosody.core.configmanager";
local modulemanager = require "prosody.core.modulemanager";
local events_new = require "prosody.util.events".new;
local disco_items = require "prosody.util.multitable".new();
local NULL = {};

local log = require "prosody.util.logger".init("hostmanager");

local hosts = prosody.hosts;
local prosody_events = prosody.events;
if not _G.prosody.incoming_s2s then
	require "prosody.core.s2smanager";
end
local incoming_s2s = _G.prosody.incoming_s2s;
local core_route_stanza = _G.prosody.core_route_stanza;

local pairs, rawget = pairs, rawget;
local tostring, type = tostring, type;
local setmetatable = setmetatable;

local _ENV = nil;
-- luacheck: std none

local host_mt = { }
function host_mt:__tostring()
	if self.type == "component" then
		local typ = configmanager.get(self.host, "component_module");
		if typ == "component" then
			return ("Component %q"):format(self.host);
		end
		return ("Component %q %q"):format(self.host, typ);
	elseif self.type == "local" then
		return ("VirtualHost %q"):format(self.host);
	end
end

local hosts_loaded_once;

local activate, deactivate;

local function load_enabled_hosts(config)
	local defined_hosts = config or configmanager.getconfig();
	local activated_any_host;

	for host, host_config in pairs(defined_hosts) do
		if host ~= "*" and host_config.enabled ~= false then
			if not host_config.component_module then
				activated_any_host = true;
			end
			activate(host, host_config);
		end
	end

	if not activated_any_host then
		log("error", "No active VirtualHost entries in the config file. This may cause unexpected behaviour as no modules will be loaded.");
	end

	prosody_events.fire_event("hosts-activated", defined_hosts);
	hosts_loaded_once = true;
end

prosody_events.add_handler("server-starting", load_enabled_hosts);

local function host_send(stanza)
	core_route_stanza(nil, stanza);
end

function activate(host, host_config)
	if rawget(hosts, host) then return nil, "The host "..host.." is already activated"; end
	host_config = host_config or configmanager.getconfig()[host];
	if not host_config then return nil, "Couldn't find the host "..tostring(host).." defined in the current config"; end
	local host_session = {
		host = host;
		s2sout = {};
		events = events_new();
		send = host_send;
		modules = {};
	};
	function host_session:close(reason)
		log("debug", "Attempt to close host session %s with reason: %s", self.host, reason);
	end
	setmetatable(host_session, host_mt);
	if not host_config.component_module then -- host
		host_session.type = "local";
		host_session.sessions = {};
	else -- component
		host_session.type = "component";
	end
	hosts[host] = host_session;
	if not host_config.disco_hidden and not host:match("[@/]") then
		disco_items:set(host:match("%.(.*)") or "*", host, host_config.name or true);
	end
	for option_name in pairs(host_config) do
		if option_name:match("_ports$") or option_name:match("_interface$") then
			log("warn", "%s: Option '%s' has no effect for virtual hosts - put it in the server-wide section instead", host, option_name);
		end
	end

	log((hosts_loaded_once and "info") or "debug", "Activated host: %s", host);
	prosody_events.fire_event("host-activated", host);
	return true;
end

function deactivate(host, reason)
	local host_session = hosts[host];
	if not host_session then return nil, "The host "..tostring(host).." is not activated"; end
	log("info", "Deactivating host: %s", host);
	prosody_events.fire_event("host-deactivating", { host = host, host_session = host_session, reason = reason });

	if type(reason) ~= "table" then
		reason = { condition = "host-gone", text = tostring(reason or "This server has stopped serving "..host) };
	end

	-- Disconnect local users, s2s connections
	-- TODO: These should move to mod_c2s and mod_s2s (how do they know they're being unloaded and not reloaded?)
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

	-- TODO: This should be done in modulemanager
	if host_session.modules then
		for module in pairs(host_session.modules) do
			modulemanager.unload(host, module);
		end
	end

	hosts[host] = nil;
	if not host:match("[@/]") then
		disco_items:remove(host:match("%.(.*)") or "*", host);
	end
	prosody_events.fire_event("host-deactivated", host);
	log("info", "Deactivated host: %s", host);
	return true;
end

local function get_children(host)
	return disco_items:get(host) or NULL;
end

return {
	activate = activate;
	deactivate = deactivate;
	get_children = get_children;
}
