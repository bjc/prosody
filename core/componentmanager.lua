-- Prosody IM v0.3
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--




local log = require "util.logger".init("componentmanager");
local configmanager = require "core.configmanager";
local eventmanager = require "core.eventmanager";
local modulemanager = require "core.modulemanager";
local jid_split = require "util.jid".split;
local hosts = hosts;

local pairs, type, tostring = pairs, type, tostring;

local components = {};

module "componentmanager"

function load_enabled_components(config)
	local defined_hosts = config or configmanager.getconfig();
		
	for host, host_config in pairs(defined_hosts) do
		if host ~= "*" and ((host_config.core.enabled == nil or host_config.core.enabled) and type(host_config.core.component_module) == "string") then
			hosts[host] = { type = "component", host = host, connected = true, s2sout = {} };
			modulemanager.load(host, "dialback");
			local ok, err = modulemanager.load(host, host_config.core.component_module);
			if not ok then
				log("error", "Error loading %s component %s: %s", tostring(host_config.core.component_module), tostring(host), tostring(err));
			else
				log("info", "Activated %s component: %s", host_config.core.component_module, host);
			end
			
			local ok, component_handler = modulemanager.call_module_method(modulemanager.get_module(host, host_config.core.component_module), "load_component");
			if not ok then
				log("error", "Error loading %s component %s: %s", tostring(host_config.core.component_module), tostring(host), tostring(component_handler));
			else
				components[host] = component_handler;
			end
		end
	end
end

eventmanager.add_event_hook("server-starting", load_enabled_components);

function handle_stanza(origin, stanza)
	local node, host = jid_split(stanza.attr.to);
	local component = nil;
	if not component then component = components[stanza.attr.to]; end -- hack to allow hooking node@server/resource and server/resource
	if not component then component = components[node.."@"..host]; end -- hack to allow hooking node@server
	if not component then component = components[host]; end
	if component then
		log("debug", "stanza being handled by component: "..host);
		component(origin, stanza, hosts[host]);
	else
		log("error", "Component manager recieved a stanza for a non-existing component: " .. stanza.attr.to);
	end
end

function register_component(host, component)
	if not hosts[host] then
		-- TODO check for host well-formedness
		components[host] = component;
		hosts[host] = { type = "component", host = host, connected = true, s2sout = {} };
		-- FIXME only load for a.b.c if b.c has dialback, and/or check in config
		modulemanager.load(host, "dialback");
		log("debug", "component added: "..host);
		return hosts[host];
	else
		log("error", "Attempt to set component for existing host: "..host);
	end
end

function deregister_component(host)
	if components[host] then
		modulemanager.unload(host, "dialback");
		components[host] = nil;
		hosts[host] = nil;
		log("debug", "component removed: "..host);
		return true;
	else
		log("error", "Attempt to remove component for non-existing host: "..host);
	end
end

return _M;
