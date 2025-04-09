-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local array = require "prosody.util.array";
local logger = require "prosody.util.logger";
local log = logger.init("modulemanager");
local config = require "prosody.core.configmanager";
local pluginloader = require "prosody.util.pluginloader";
local envload = require "prosody.util.envload";
local set = require "prosody.util.set";

local core_features = require "prosody.core.features".available;

local new_multitable = require "prosody.util.multitable".new;
local api = require "prosody.core.moduleapi"; -- Module API container

local prosody = prosody;
local hosts = prosody.hosts;

local xpcall = require "prosody.util.xpcall".xpcall;
local debug_traceback = debug.traceback;
local setmetatable, rawget = setmetatable, rawget;
local ipairs, pairs, type, t_insert = ipairs, pairs, type, table.insert;
local lua_version = _VERSION:match("5%.%d+$");

local autoload_modules = {
	"presence",
	"message",
	"iq",
	"offline",
	"c2s",
	"s2s",
	"s2s_auth_certs",
};
local component_inheritable_modules = {
	"tls",
	"saslauth",
	"dialback",
	"iq",
	"s2s",
	"s2s_bidi",
	"smacks",
	"server_contact_info",
};

-- We need this to let modules access the real global namespace
local _G = _G;

local _ENV = nil;
-- luacheck: std none

local function plugin_load_filter_cb(path, content)
	local metadata = {};
	for line in content:gmatch("([^\r\n]+)\r?\n") do
		local key, value = line:match("^%-%-%% *([%w_]+): *(.+)$");
		if key then
			value = value:gsub("%s+$", "");
			metadata[key] = value;
		end
	end

	if metadata.lua then
		local supported = false;
		for supported_lua_version in metadata.lua:gmatch("[^, ]+") do
			if supported_lua_version == lua_version then
				supported = true;
				break;
			end
		end
		if not supported then
			if prosody.process_type ~= "prosodyctl" then
				log("warn", "Not loading module, we have Lua %s but the module requires one of (%s): %s", lua_version, metadata.lua, path);
			end
			return nil, "incompatible with Lua "..lua_version; -- Don't load this module
		end
	end

	if metadata.conflicts then
		local conflicts_features = set.new(array.collect(metadata.conflicts:gmatch("[^, ]+")));
		local conflicted_features = set.intersection(conflicts_features, core_features);
		if not conflicted_features:empty() then
			if prosody.process_type ~= "prosodyctl" then
				log("warn", "Not loading module, due to conflict with built-in features '%s': %s", conflicted_features, path);
			end
			return nil, "conflict with built-in feature"; -- Don't load this module
		end
	end
	if metadata.requires then
		local required_features = set.new(array.collect(metadata.requires:gmatch("[^, ]+")));
		local missing_features = required_features - core_features;
		if not missing_features:empty() then
			if prosody.process_type ~= "prosodyctl" then
				log("warn", "Not loading module, due to missing features '%s': %s", missing_features, path);
			end
			return nil, "Prosody version missing required feature"; -- Don't load this module
		end
	end

	return path, content, metadata;
end;

local loader = pluginloader.init({
	load_filter_cb = plugin_load_filter_cb;
});

local load_modules_for_host, load, unload, reload, get_module, get_items;
local get_modules, is_loaded, module_has_method, call_module_method;

-- [host] = { [module] = module_env }
local modulemap = { ["*"] = {} };

-- Get the list of modules to be loaded on a host
local function get_modules_for_host(host)
	local component = config.get(host, "component_module");

	local global_modules_enabled = config.get("*", "modules_enabled");
	local global_modules_disabled = config.get("*", "modules_disabled");
	local host_modules_enabled = config.get(host, "modules_enabled");
	local host_modules_disabled = config.get(host, "modules_disabled");

	if host_modules_enabled == global_modules_enabled then host_modules_enabled = nil; end
	if host_modules_disabled == global_modules_disabled then host_modules_disabled = nil; end

	local global_modules = set.new(autoload_modules) + set.new(global_modules_enabled) - set.new(global_modules_disabled);
	if component then
		global_modules = set.intersection(set.new(component_inheritable_modules), global_modules);
	end
	local modules = (global_modules + set.new(host_modules_enabled)) - set.new(host_modules_disabled);

	if modules:contains("vcard") and modules:contains("vcard_legacy") then
		log("error", "The mod_vcard_legacy plugin replaces mod_vcard but both are enabled. Please update your config.");
		modules:remove("vcard");
	end

	return modules, component;
end

-- Load modules when a host is activated
function load_modules_for_host(host)
	local modules, component_module = get_modules_for_host(host);

	-- Ensure component module is loaded first
	if component_module then
		load(host, component_module);
	end
	for module in modules do
		load(host, module);
	end
end
prosody.events.add_handler("host-activated", load_modules_for_host);
prosody.events.add_handler("host-deactivated", function (host)
	modulemap[host] = nil;
end);

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

	for object, event, handler in mod.module.event_handlers:iter(nil, nil, nil) do
		object.remove_handler(event, handler);
	end

	if mod.module.items then -- remove items
		local events = (host == "*" and prosody.events) or hosts[host].events;
		for key,t in pairs(mod.module.items) do
			for i = #t,1,-1 do
				local value = t[i];
				t[i] = nil;
				events.fire_event("item-removed/"..key, {source = mod.module, item = value});
			end
		end
	end
	mod.module.loaded = false;
	modulemap[host][name] = nil;
	return true;
end

local function do_load_module(host, module_name, state)
	if not (host and module_name) then
		return nil, "insufficient-parameters";
	elseif not hosts[host] and host ~= "*"then
		return nil, "unknown-host";
	end

	if not modulemap[host] then
		modulemap[host] = hosts[host].modules;
	end

	if modulemap[host][module_name] then
		if not modulemap["*"][module_name] then
			log("debug", "%s is already loaded for %s, so not loading again", module_name, host);
		end
		return nil, "module-already-loaded";
	elseif modulemap["*"][module_name] then
		local mod = modulemap["*"][module_name];
		if module_has_method(mod, "add_host") then
			local _log = logger.init(host..":"..module_name);
			local host_module_api = setmetatable({
				global = false,
				host = host, event_handlers = new_multitable(), items = {};
				_log = _log, log = function (self, ...) return _log(...); end; --luacheck: ignore 212/self
			},{
				__index = modulemap["*"][module_name].module;
			});
			local host_module = setmetatable({ module = host_module_api }, { __index = mod });
			host_module_api.environment = host_module;
			modulemap[host][module_name] = host_module;
			local ok, result, module_err = call_module_method(mod, "add_host", host_module_api);
			if not ok or result == false then
				modulemap[host][module_name] = nil;
				return nil, ok and module_err or result;
			end
			return host_module;
		end
		return nil, "global-module-already-loaded";
	end



	local _log = logger.init(host..":"..module_name);
	local api_instance = setmetatable({ name = module_name, host = host,
		_log = _log, log = function (self, ...) return _log(...); end, --luacheck: ignore 212/self
		event_handlers = new_multitable(), reloading = not not state,
		saved_state = state~=true and state or nil }
		, { __index = api });

	local pluginenv = setmetatable({ module = api_instance }, { __index = _G });
	api_instance.environment = pluginenv;

	local mod, err, meta = loader:load_code(module_name, nil, pluginenv);
	if not mod then
		log("error", "Unable to load module '%s': %s", module_name or "nil", err or "nil");
		api_instance:set_status("error", "Failed to load (see log)");
		return nil, err;
	end

	api_instance.path = err;
	api_instance.meta = meta;

	local custom_plugins = prosody.paths.installer;
	if custom_plugins and err:sub(1, #custom_plugins+1) == custom_plugins.."/" then
		-- Stage 1: Make it work (you are here)
		-- Stage 2: Make it less hacky (TODO)
		local manifest = {};
		local luarocks_path = custom_plugins.."/lib/luarocks/rocks-"..lua_version;
		local manifest_filename = luarocks_path.."/manifest";
		local load_manifest, err = envload.envloadfile(manifest_filename, manifest);
		if not load_manifest then
			-- COMPAT Luarocks 2.x
			log("debug", "Could not load LuaRocks 3.x manifest, trying 2.x", err);
			luarocks_path = custom_plugins.."/lib/luarocks/rocks";
			manifest_filename = luarocks_path.."/manifest";
			load_manifest, err = envload.envloadfile(manifest_filename, manifest);
		end
		if not load_manifest then
			log("error", "Could not load manifest of installed plugins: %s", err, load_manifest);
		else
			local ok, err = xpcall(load_manifest, debug_traceback);
			if not ok then
				log("error", "Could not load manifest of installed plugins: %s", err);
			elseif type(manifest.modules) ~= "table" then
				log("debug", "Expected 'table' but manifest.modules = %q", manifest.modules);
				log("error", "Can't look up resource path for mod_%s because '%s' does not appear to be a LuaRocks manifest", module_name, manifest_filename);
			else
				local versions = manifest.modules["mod_"..module_name];
				if type(versions) == "table" and versions[1] then
					-- Not going to deal with multiple installed versions
					api_instance.resource_path = luarocks_path.."/"..versions[1];
				else
					log("debug", "mod_%s does not appear in the installation manifest", module_name);
				end
			end
		end
	end

	modulemap[host][module_name] = pluginenv;
	local ok, err = xpcall(mod, debug_traceback);
	if ok then
		-- Call module's "load"
		if module_has_method(pluginenv, "load") then
			ok, err = call_module_method(pluginenv, "load");
			if not ok then
				log("warn", "Error loading module '%s' on '%s': %s", module_name, host, err or "nil");
				api_instance:set_status("warn", "Error during load (see log)");
			end
		end
		api_instance.reloading, api_instance.saved_state = nil, nil;

		if api_instance.host == "*" then
			if not api_instance.global then -- COMPAT w/pre-0.9
				if host ~= "*" then
					log("warn", "mod_%s: Setting module.host = '*' deprecated, call module:set_global() instead", module_name);
				end
				api_instance:set_global();
			end
			modulemap[host][module_name] = nil;
			modulemap[api_instance.host][module_name] = pluginenv;
			if host ~= api_instance.host and module_has_method(pluginenv, "add_host") then
				-- Now load the module again onto the host it was originally being loaded on
				ok, err = do_load_module(host, module_name);
			end
		end

		if module_has_method(pluginenv, "ready") then
			pluginenv.module:on_ready(pluginenv.module.ready);
		end
	end
	if not ok then
		modulemap[api_instance.host][module_name] = nil;
		log("error", "Error initializing module '%s' on '%s': %s", module_name, host, err or "nil");
		api_instance:set_status("warn", "Error during load (see log)");
	else
		api_instance:set_status("core", "Loaded", false);
	end
	return ok and pluginenv, err;
end

local function do_reload_module(host, name)
	local mod = get_module(host, name);
	if not mod then return nil, "module-not-loaded"; end

	local _mod, err = loader:load_code(name); -- checking for syntax errors
	if not _mod then
		log("error", "Unable to load module '%s': %s", name or "nil", err or "nil");
		return nil, err;
	end

	local saved;
	if module_has_method(mod, "save") then
		-- FIXME What goes in 'err' here?
		local ok, ret, err = call_module_method(mod, "save"); -- luacheck: ignore 211/err
		if ok then
			saved = ret;
		else
			log("warn", "Error saving module '%s:%s' state: %s", host, name, ret);
			if not config.get(host, "force_module_reload") then
				log("warn", "Aborting reload due to error, set force_module_reload to ignore this");
				return nil, "save-state-failed";
			else
				log("warn", "Continuing with reload (using the force)");
			end
		end
	end

	mod.module.reloading = true;
	do_unload_module(host, name);
	local ok, err = do_load_module(host, name, saved or true);
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
		(hosts[mod.module.host] or prosody).events.fire_event("module-loaded", { module = name, host = mod.module.host });
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
	local mod, err = do_reload_module(host, name);
	if mod then
		modulemap[host][name].module.reloading = true;
		(hosts[host] or prosody).events.fire_event("module-reloaded", { module = name, host = host });
		mod.module.reloading = nil;
	elseif not is_loaded(host, name) then
		(hosts[host] or prosody).events.fire_event("module-unloaded", { module = name, host = host });
	end
	return mod, err;
end

function get_module(host, name)
	return modulemap[host] and modulemap[host][name];
end

function get_items(key, host)
	local result = {};
	local modules = modulemap[host];
	if not key or not host or not modules then return nil; end

	for _, module in pairs(modules) do
		local mod = module.module;
		if mod.items and mod.items[key] then
			for _, value in ipairs(mod.items[key]) do
				t_insert(result, value);
			end
		end
	end

	return result;
end

function get_modules(host)
	return modulemap[host];
end

function is_loaded(host, name)
	return modulemap[host] and modulemap[host][name] and true;
end

function module_has_method(module, method)
	return type(rawget(module.module, method)) == "function";
end

function call_module_method(module, method, ...)
	local f = rawget(module.module, method);
	if type(f) == "function" then
		return xpcall(f, debug_traceback, ...);
	else
		return false, "no-such-method";
	end
end

return {
	get_modules_for_host = get_modules_for_host;
	load_modules_for_host = load_modules_for_host;
	load = load;
	unload = unload;
	reload = reload;
	get_module = get_module;
	get_items = get_items;
	get_modules = get_modules;
	is_loaded = is_loaded;
	module_has_method = module_has_method;
	call_module_method = call_module_method;

	loader = loader;
};
