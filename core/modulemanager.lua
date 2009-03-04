-- Prosody IM v0.3
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local plugin_dir = CFG_PLUGINDIR or "./plugins/";

local logger = require "util.logger";
local log = logger.init("modulemanager");
local addDiscoInfoHandler = require "core.discomanager".addDiscoInfoHandler;
local eventmanager = require "core.eventmanager";
local config = require "core.configmanager";
local multitable_new = require "util.multitable".new;
local register_actions = require "core.actions".register;

local hosts = hosts;

local loadfile, pcall = loadfile, pcall;
local setmetatable, setfenv, getfenv = setmetatable, setfenv, getfenv;
local pairs, ipairs = pairs, ipairs;
local t_insert, t_concat = table.insert, table.concat;
local type = type;
local next = next;
local rawget = rawget;

local tostring, print = tostring, print;

-- We need this to let modules access the real global namespace
local _G = _G;

module "modulemanager"

local api = {}; -- Module API container

local modulemap = { ["*"] = {} };

local stanza_handlers = multitable_new();
local handler_info = {};

local modulehelpers = setmetatable({}, { __index = _G });

local features_table = multitable_new();
local handler_table = multitable_new();
local hooked = multitable_new();
local event_hooks = multitable_new();

local NULL = {};

-- Load modules when a host is activated
function load_modules_for_host(host)
	-- Load modules from global section
	local modules_enabled = config.get("*", "core", "modules_enabled");
	local modules_disabled = config.get(host, "core", "modules_disabled");
	local disabled_set = {};
	if modules_enabled then
		if modules_disabled then
			for _, module in ipairs(modules_disabled) do
				disabled_set[module] = true;
			end
		end
		for _, module in ipairs(modules_enabled) do
			if not disabled_set[module] then
				load(host, module);
			end
		end
	end

	-- Load modules from just this host
	local modules_enabled = config.get(host, "core", "modules_enabled");
	if modules_enabled then
		for _, module in pairs(modules_enabled) do
			if not is_loaded(host, module) then
				load(host, module);
			end
		end
	end
end
eventmanager.add_event_hook("host-activated", load_modules_for_host);
--

function load(host, module_name, config)
	if not (host and module_name) then
		return nil, "insufficient-parameters";
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
	

	local mod, err = loadfile(get_module_filename(module_name));
	if not mod then
		log("error", "Unable to load module '%s': %s", module_name or "nil", err or "nil");
		return nil, err;
	end

	local _log = logger.init(host..":"..module_name);
	local api_instance = setmetatable({ name = module_name, host = host, config = config,  _log = _log, log = function (self, ...) return _log(...); end }, { __index = api });

	local pluginenv = setmetatable({ module = api_instance }, { __index = _G });
	
	setfenv(mod, pluginenv);
	if not hosts[host] then hosts[host] = { type = "component", host = host, connected = false, s2sout = {} }; end
	
	local success, ret = pcall(mod);
	if not success then
		log("error", "Error initialising module '%s': %s", name or "nil", ret or "nil");
		return nil, ret;
	end
	
	-- Use modified host, if the module set one
	modulemap[api_instance.host][module_name] = pluginenv;
	
	return true;
end

function get_module(host, name)
	return modulemap[host] and modulemap[host][name];
end

function is_loaded(host, name)
	return modulemap[host] and modulemap[host][name] and true;
end

function unload(host, name, ...)
	local mod = get_module(host, name); 
	if not mod then return nil, "module-not-loaded"; end
	
	if module_has_method(mod, "unload") then
		local ok, err = call_module_method(mod, "unload");
		if (not ok) and err then
			log("warn", "Non-fatal error unloading module '%s' on '%s': %s", name, host, err);
		end
	end
	modulemap[host][name] = nil;
	features_table:remove(host, name);
	local params = handler_table:get(host, name); -- , {module.host, origin_type, tag, xmlns}
	for _, param in pairs(params or NULL) do
		local handlers = stanza_handlers:get(param[1], param[2], param[3], param[4]);
		if handlers then
			handler_info[handlers[1]] = nil;
			stanza_handlers:remove(param[1], param[2], param[3], param[4]);
		end
	end
	event_hooks:remove(host, name);
	return true;
end

function reload(host, name, ...)
	local mod = get_module(host, name);
	if not mod then return nil, "module-not-loaded"; end

	local _mod, err = loadfile(get_module_filename(name)); -- checking for syntax errors
	if not _mod then
		log("error", "Unable to load module '%s': %s", module_name or "nil", err or "nil");
		return nil, err;
	end

	local saved;

	if module_has_method(mod, "save") then
		local ok, ret, err = call_module_method(mod, "save");
		if ok then
			saved = ret;
		else
			log("warn", "Error saving module '%s:%s' state: %s", host, module, ret);
			if not config.get(host, "core", "force_module_reload") then
				log("warn", "Aborting reload due to error, set force_module_reload to ignore this");
				return nil, "save-state-failed";
			else
				log("warn", "Continuing with reload (using the force)");
			end
		end
	end

	unload(host, name, ...);
	local ok, err = load(host, name, ...);
	if ok then
		mod = get_module(host, name);
		if module_has_method(mod, "restore") then
			local ok, err = call_module_method(mod, "restore", saved or {})
			if (not ok) and err then
				log("warn", "Error restoring module '%s' from '%s': %s", name, host, err);
			end
		end
		return true;
	end
	return ok, err;
end

function handle_stanza(host, origin, stanza)
	local name, xmlns, origin_type = stanza.name, stanza.attr.xmlns, origin.type;
	if name == "iq" and xmlns == "jabber:client" then
		if stanza.attr.type == "get" or stanza.attr.type == "set" then
			xmlns = stanza.tags[1].attr.xmlns;
			log("debug", "Stanza of type %s from %s has xmlns: %s", name, origin_type, xmlns);
		else
			log("debug", "Discarding %s from %s of type: %s", name, origin_type, stanza.attr.type);
			return true;
		end
	end
	local handlers = stanza_handlers:get(host, origin_type, name, xmlns);
	if not handlers then handlers = stanza_handlers:get("*", origin_type, name, xmlns); end
	if handlers then
		log("debug", "Passing stanza to mod_%s", handler_info[handlers[1]].name);
		(handlers[1])(origin, stanza);
		return true;
	else
		log("debug", "Stanza unhandled by any modules, xmlns: %s", stanza.attr.xmlns); -- we didn't handle it
	end
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

local _modulepath = { plugin_dir, "mod_", nil, ".lua"};
function get_module_filename(name)
	_modulepath[3] = name;
	return t_concat(_modulepath);
end

----- API functions exposed to modules -----------
-- Must all be in api.* 

-- Returns the name of the current module
function api:get_name()
	return self.name;
end

-- Returns the host that the current module is serving
function api:get_host()
	return self.host;
end

function api:get_host_type()
	return hosts[self.host].type;
end

function api:set_global()
	self.host = "*";
end

local function _add_handler(module, origin_type, tag, xmlns, handler)
	local handlers = stanza_handlers:get(module.host, origin_type, tag, xmlns);
	local msg = (tag == "iq") and "namespace" or "payload namespace";
	if not handlers then
		stanza_handlers:add(module.host, origin_type, tag, xmlns, handler);
		handler_info[handler] = module;
		handler_table:add(module.host, module.name, {module.host, origin_type, tag, xmlns});
		--module:log("debug", "I now handle tag '%s' [%s] with %s '%s'", tag, origin_type, msg, xmlns);
	else
		module:log("warn", "I wanted to handle tag '%s' [%s] with %s '%s' but mod_%s already handles that", tag, origin_type, msg, xmlns, handler_info[handlers[1]].module.name);
	end
end

function api:add_handler(origin_type, tag, xmlns, handler)
	if not (origin_type and tag and xmlns and handler) then return false; end
	if type(origin_type) == "table" then
		for _, origin_type in ipairs(origin_type) do
			_add_handler(self, origin_type, tag, xmlns, handler);
		end
	else
		_add_handler(self, origin_type, tag, xmlns, handler);
	end
end
function api:add_iq_handler(origin_type, xmlns, handler)
	self:add_handler(origin_type, "iq", xmlns, handler);
end

addDiscoInfoHandler("*host", function(reply, to, from, node)
	if #node == 0 then
		local done = {};
		for module, features in pairs(features_table:get(to) or NULL) do -- for each module
			for feature in pairs(features) do
				if not done[feature] then
					reply:tag("feature", {var = feature}):up(); -- TODO cache
					done[feature] = true;
				end
			end
		end
		return next(done) ~= nil;
	end
end);

function api:add_feature(xmlns)
	features_table:set(self.host, self.name, xmlns, true);
end

local event_hook = function(host, mod_name, event_name, ...)
	if type((...)) == "table" and (...).host and (...).host ~= host then return; end
	for handler in pairs(event_hooks:get(host, mod_name, event_name) or NULL) do
		handler(...);
	end
end;
function api:add_event_hook(name, handler)
	if not hooked:get(self.host, self.name, name) then
		eventmanager.add_event_hook(name, function(...) event_hook(self.host, self.name, name, ...); end);
		hooked:set(self.host, self.name, name, true);
	end
	event_hooks:set(self.host, self.name, name, handler, true);
end

--------------------------------------------------------------------

local actions = {};

function actions.load(params)
	--return true, "Module loaded ("..params.module.." on "..params.host..")";
	return load(params.host, params.module);
end

function actions.unload(params)
	return unload(params.host, params.module);
end

register_actions("/modules", actions);

return _M;
