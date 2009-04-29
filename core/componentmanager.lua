-- Prosody IM v0.4
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
local core_route_stanza = core_route_stanza;
local jid_split = require "util.jid".split;
local st = require "util.stanza";
local hosts = hosts;

local pairs, type, tostring = pairs, type, tostring;

local components = {};

local disco_items = require "util.multitable".new();
local NULL = {};
require "core.discomanager".addDiscoItemsHandler("*host", function(reply, to, from, node)
	if #node == 0 and hosts[to] then
		for jid in pairs(disco_items:get(to) or NULL) do
			reply:tag("item", {jid = jid}):up();
		end
		return true;
	end
end);

require "core.eventmanager".add_event_hook("server-starting", function () core_route_stanza = _G.core_route_stanza; end);

module "componentmanager"

local function default_component_handler(origin, stanza)
	log("warn", "Stanza being handled by default component, bouncing error");
	if stanza.attr.type ~= "error" then
		core_route_stanza(nil, st.error_reply(stanza, "wait", "service-unavailable", "Component unavailable"));
	end
end


function load_enabled_components(config)
	local defined_hosts = config or configmanager.getconfig();
		
	for host, host_config in pairs(defined_hosts) do
		if host ~= "*" and ((host_config.core.enabled == nil or host_config.core.enabled) and type(host_config.core.component_module) == "string") then
			hosts[host] = { type = "component", host = host, connected = false, s2sout = {} };
			components[host] = default_component_handler;
			local ok, err = modulemanager.load(host, host_config.core.component_module);
			if not ok then
				log("error", "Error loading %s component %s: %s", tostring(host_config.core.component_module), tostring(host), tostring(err));
			else
				log("info", "Activated %s component: %s", host_config.core.component_module, host);
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
		log("debug", "%s stanza being handled by component: %s", stanza.name, host);
		component(origin, stanza, hosts[host]);
	else
		log("error", "Component manager recieved a stanza for a non-existing component: " .. stanza.attr.to);
	end
end

function create_component(host, component)
	-- TODO check for host well-formedness
	return { type = "component", host = host, connected = true, s2sout = {} };
end

function register_component(host, component, session)
	if not hosts[host] or (hosts[host].type == 'component' and not hosts[host].connected) then
		components[host] = component;
		hosts[host] = session or create_component(host, component);
		-- add to disco_items
		if not(host:find("@", 1, true) or host:find("/", 1, true)) and host:find(".", 1, true) then
			disco_items:set(host:sub(host:find(".", 1, true)+1), host, true);
		end
		-- FIXME only load for a.b.c if b.c has dialback, and/or check in config
		modulemanager.load(host, "dialback");
		log("debug", "component added: "..host);
		return session or hosts[host];
	else
		log("error", "Attempt to set component for existing host: "..host);
	end
end

function deregister_component(host)
	if components[host] then
		modulemanager.unload(host, "dialback");
		hosts[host].connected = nil;
		local host_config = configmanager.getconfig()[host];
		if host_config and ((host_config.core.enabled == nil or host_config.core.enabled) and type(host_config.core.component_module) == "string") then
			-- Set default handler
			components[host] = default_component_handler;
		else
			-- Component not in config, or disabled, remove
			hosts[host] = nil;
			components[host] = nil;
		end
		-- remove from disco_items
		if not(host:find("@", 1, true) or host:find("/", 1, true)) and host:find(".", 1, true) then
			disco_items:remove(host:sub(host:find(".", 1, true)+1), host);
		end
		log("debug", "component removed: "..host);
		return true;
	else
		log("error", "Attempt to remove component for non-existing host: "..host);
	end
end

function set_component_handler(host, handler)
	components[host] = handler;
end

return _M;
