-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local logger = require "util.logger";
local log = logger.init("modulemanager");
local config = require "core.configmanager";
local multitable_new = require "util.multitable".new;
local st = require "util.stanza";
local pluginloader = require "util.pluginloader";

local hosts = hosts;
local prosody = prosody;
local prosody_events = prosody.events;

local loadfile, pcall, xpcall = loadfile, pcall, xpcall;
local setmetatable, setfenv, getfenv = setmetatable, setfenv, getfenv;
local pairs, ipairs = pairs, ipairs;
local t_insert, t_concat = table.insert, table.concat;
local type = type;
local next = next;
local rawget = rawget;
local error = error;
local tostring, tonumber = tostring, tonumber;

local debug_traceback = debug.traceback;
local unpack, select = unpack, select;
pcall = function(f, ...)
	local n = select("#", ...);
	local params = {...};
	return xpcall(function() return f(unpack(params, 1, n)) end, function(e) return tostring(e).."\n"..debug_traceback(); end);
end

local array, set = require "util.array", require "util.set";

local autoload_modules = {"presence", "message", "iq", "offline"};
local component_inheritable_modules = {"tls", "dialback", "iq"};

-- We need this to let modules access the real global namespace
local _G = _G;

module "modulemanager"

local api = _G.require "core.moduleapi"; -- Module API container

local modulemap = { ["*"] = {} };

local modulehelpers = setmetatable({}, { __index = _G });

local hooks = multitable_new();

local NULL = {};

-- Load modules when a host is activated
function load_modules_for_host(host)
	local component = config.get(host, "core", "component_module");
	
	local global_modules_enabled = config.get("*", "core", "modules_enabled");
	local global_modules_disabled = config.get("*", "core", "modules_disabled");
	local host_modules_enabled = config.get(host, "core", "modules_enabled");
	local host_modules_disabled = config.get(host, "core", "modules_disabled");
	
	if host_modules_enabled == global_modules_enabled then host_modules_enabled = nil; end
	if host_modules_disabled == global_modules_disabled then host_modules_disabled = nil; end
	
	local global_modules = set.new(autoload_modules) + set.new(global_modules_enabled) - set.new(global_modules_disabled);
	if component then
		global_modules = set.intersection(set.new(component_inheritable_modules), global_modules);
	end
	local modules = (global_modules + set.new(host_modules_enabled)) - set.new(host_modules_disabled);
	
	-- COMPAT w/ pre 0.8
	if modules:contains("console") then
		log("error", "The mod_console plugin has been renamed to mod_admin_telnet. Please update your config.");
		modules:remove("console");
		modules:add("admin_telnet");
	end
	
	if component then
		load(host, component);
	end
	for module in modules do
		load(host, module);
	end
end
prosody_events.add_handler("host-activated", load_modules_for_host);
--

--- Private helpers ---

local function do_unload_module(host, name)
	local mod = get_module(host, name);
	if not mod then return nil, "module-not-loaded"; end
	
	if module_has_method(mod, "unload") then
		local ok, err = call_module_method(mod, "unload");
		if (not ok) and err then
			log("warn", "Non-fatal error unloading module '%s' on '%s': %s", name, host, err);
		end
	end
	-- unhook event handlers hooked by module:hook
	for event, handlers in pairs(hooks:get(host, name) or NULL) do
		for handler in pairs(handlers or NULL) do
			(hosts[host] or prosody).events.remove_handler(event, handler);
		end
	end
	-- unhook event handlers hooked by module:hook_global
	for event, handlers in pairs(hooks:get("*", name) or NULL) do
		for handler in pairs(handlers or NULL) do
			prosody.events.remove_handler(event, handler);
		end
	end
	hooks:remove(host, name);
	if mod.module.items then -- remove items
		for key,t in pairs(mod.module.items) do
			for i = #t,1,-1 do
				local value = t[i];
				t[i] = nil;
				hosts[host].events.fire_event("item-removed/"..key, {source = mod.module, item = value});
			end
		end
	end
	modulemap[host][name] = nil;
	return true;
end

local function do_load_module(host, module_name)
	if not (host and module_name) then
		return nil, "insufficient-parameters";
	elseif not hosts[host] then
		return nil, "unknown-host";
	end
	
	if not modulemap[host] then
		modulemap[host] = {};
	end
	
	if modulemap[host][module_name] then
		log("warn", "%s is already loaded for %s, so not loading again", module_name, host);
		return nil, "module-already-loaded";
	elseif modulemap["*"][module_name] then
		return nil, "global-module-already-loaded";
	end
	

	local mod, err = pluginloader.load_code(module_name);
	if not mod then
		log("error", "Unable to load module '%s': %s", module_name or "nil", err or "nil");
		return nil, err;
	end

	local _log = logger.init(host..":"..module_name);
	local api_instance = setmetatable({ name = module_name, host = host, path = err,
		_log = _log, log = function (self, ...) return _log(...); end }
		, { __index = api });

	local pluginenv = setmetatable({ module = api_instance }, { __index = _G });
	api_instance.environment = pluginenv;
	
	setfenv(mod, pluginenv);
	hosts[host].modules = modulemap[host];
	modulemap[host][module_name] = pluginenv;
	
	local ok, err = pcall(mod);
	if ok then
		-- Call module's "load"
		if module_has_method(pluginenv, "load") then
			ok, err = call_module_method(pluginenv, "load");
			if not ok then
				log("warn", "Error loading module '%s' on '%s': %s", module_name, host, err or "nil");
			end
		end

		-- Use modified host, if the module set one
		if api_instance.host == "*" and host ~= "*" then
			modulemap[host][module_name] = nil;
			modulemap["*"][module_name] = pluginenv;
			api_instance:set_global();
		end
	else
		log("error", "Error initializing module '%s' on '%s': %s", module_name, host, err or "nil");
		do_unload_module(api_instance.host, module_name); -- Ignore error, module may be partially-loaded
	end
	return ok and mod, err;
end

local function do_reload_module(host, name)
	local mod = get_module(host, name);
	if not mod then return nil, "module-not-loaded"; end

	local _mod, err = pluginloader.load_code(name); -- checking for syntax errors
	if not _mod then
		log("error", "Unable to load module '%s': %s", name or "nil", err or "nil");
		return nil, err;
	end

	local saved;

	if module_has_method(mod, "save") then
		local ok, ret, err = call_module_method(mod, "save");
		if ok then
			saved = ret;
		else
			log("warn", "Error saving module '%s:%s' state: %s", host, name, ret);
			if not config.get(host, "core", "force_module_reload") then
				log("warn", "Aborting reload due to error, set force_module_reload to ignore this");
				return nil, "save-state-failed";
			else
				log("warn", "Continuing with reload (using the force)");
			end
		end
	end

	do_unload_module(host, name);
	local ok, err = do_load_module(host, name);
	if ok then
		mod = get_module(host, name);
		if module_has_method(mod, "restore") then
			local ok, err = call_module_method(mod, "restore", saved or {})
			if (not ok) and err then
				log("warn", "Error restoring module '%s' from '%s': %s", name, host, err);
			end
		end
	end
	return ok and mod, err;
end

--- Public API ---

-- Load a module and fire module-loaded event
function load(host, name)
	local mod, err = do_load_module(host, name);
	if mod then
		(hosts[mod.host] or prosody).events.fire_event("module-loaded", { module = module_name, host = host });
	end
	return mod, err;
end

-- Unload a module and fire module-unloaded
function unload(host, name)
	local ok, err = do_unload_module(host, name);
	if ok then
		(hosts[host] or prosody).events.fire_event("module-unloaded", { module = name, host = host });
	end
	return ok, err;
end

function reload(host, name)
	local ok, err = do_reload_module(host, name);
	if ok then
		(hosts[host] or prosody).events.fire_event("module-reloaded", { module = name, host = host });
	elseif not is_loaded(host, name) then
		(hosts[host] or prosody).events.fire_event("module-unloaded", { module = name, host = host });
	end
	return ok, err;
end

function get_module(host, name)
	return modulemap[host] and modulemap[host][name];
end

function get_modules(host)
	return modulemap[host];
end

function is_loaded(host, name)
	return modulemap[host] and modulemap[host][name] and true;
end

function module_has_method(module, method)
	return type(module.module[method]) == "function";
end

function call_module_method(module, method, ...)
	if module_has_method(module, method) then
		local f = module.module[method];
		return pcall(f, ...);
	else
		return false, "no-such-method";
	end
end

return _M;
