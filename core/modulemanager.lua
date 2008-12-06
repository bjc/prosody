-- Prosody IM v0.1
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--



local plugin_dir = CFG_PLUGINDIR or "./plugins/";

local logger = require "util.logger";
local log = logger.init("modulemanager");
local addDiscoInfoHandler = require "core.discomanager".addDiscoInfoHandler;
local eventmanager = require "core.eventmanager";
local config = require "core.configmanager";


local loadfile, pcall = loadfile, pcall;
local setmetatable, setfenv, getfenv = setmetatable, setfenv, getfenv;
local pairs, ipairs = pairs, ipairs;
local t_insert = table.insert;
local type = type;

local tostring, print = tostring, print;

-- We need this to let modules access the real global namespace
local _G = _G;

module "modulemanager"

local api = {}; -- Module API container

local modulemap = {};

local handler_info = {};
local stanza_handlers = {};

local modulehelpers = setmetatable({}, { __index = _G });

-- Load modules when a host is activated
function load_modules_for_host(host)
	local modules_enabled = config.get(host, "core", "modules_enabled");
	if modules_enabled then
		for _, module in pairs(modules_enabled) do
			load(host, module);
		end
	end
end
eventmanager.add_event_hook("host-activated", load_modules_for_host);
--

function load(host, module_name, config)
	if not (host and module_name) then
		return nil, "insufficient-parameters";
	end
	local mod, err = loadfile(plugin_dir.."mod_"..module_name..".lua");
	if not mod then
		log("error", "Unable to load module '%s': %s", module_name or "nil", err or "nil");
		return nil, err;
	end
	
	if not modulemap[host] then
		modulemap[host] = {};
		stanza_handlers[host] = {};
	elseif modulemap[host][module_name] then
		log("warn", "%s is already loaded for %s, so not loading again", module_name, host);
		return nil, "module-already-loaded";
	end
	
	local _log = logger.init(host..":"..module_name);
	local api_instance = setmetatable({ name = module_name, host = host, config = config,  _log = _log, log = function (self, ...) return _log(...); end }, { __index = api });

	local pluginenv = setmetatable({ module = api_instance }, { __index = _G });
	
	setfenv(mod, pluginenv);
	
	local success, ret = pcall(mod);
	if not success then
		log("error", "Error initialising module '%s': %s", name or "nil", ret or "nil");
		return nil, ret;
	end
	
	modulemap[host][module_name] = mod;
	
	return true;
end

function is_loaded(host, name)
	return modulemap[host] and modulemap[host][name] and true;
end

function unload(host, name, ...)
	local mod = modulemap[host] and modulemap[host][name];
	if not mod then return nil, "module-not-loaded"; end
	
	if type(mod.unload) == "function" then
		local ok, err = pcall(mod.unload, ...)
		if (not ok) and err then
			log("warn", "Non-fatal error unloading module '%s' from '%s': %s", name, host, err);
		end
	end
	
end

function handle_stanza(host, origin, stanza)
	local name, xmlns, origin_type = stanza.name, stanza.attr.xmlns, origin.type;
	
	local handlers = stanza_handlers[host];
	if not handlers then
		log("warn", "No handlers for %s", host);
		return false;
	end
	
	if name == "iq" and xmlns == "jabber:client" and handlers[origin_type] then
		local child = stanza.tags[1];
		if child then
			local xmlns = child.attr.xmlns or xmlns;
			log("debug", "Stanza of type %s from %s has xmlns: %s", name, origin_type, xmlns);
			local handler = handlers[origin_type][name] and handlers[origin_type][name][xmlns];
			if handler then
				log("debug", "Passing stanza to mod_%s", handler_info[handler].name);
				return handler(origin, stanza) or true;
			end
		end
	elseif handlers[origin_type] then
		local handler = handlers[origin_type][name];
		if  handler then
			handler = handler[xmlns];
			if handler then
				log("debug", "Passing stanza to mod_%s", handler_info[handler].name);
				return handler(origin, stanza) or true;
			end
		end
	end
	log("debug", "Stanza unhandled by any modules, xmlns: %s", stanza.attr.xmlns);
	return false; -- we didn't handle it
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


local function _add_iq_handler(module, origin_type, xmlns, handler)
	local handlers = stanza_handlers[module.host];
	handlers[origin_type] = handlers[origin_type] or {};
	handlers[origin_type].iq = handlers[origin_type].iq or {};
	if not handlers[origin_type].iq[xmlns] then
		handlers[origin_type].iq[xmlns]= handler;
		handler_info[handler] = module;
		module:log("debug", "I now handle tag 'iq' [%s] with payload namespace '%s'", origin_type, xmlns);
	else
		module:log("warn", "I wanted to handle tag 'iq' [%s] with payload namespace '%s' but mod_%s already handles that", origin_type, xmlns, handler_info[handlers[origin_type].iq[xmlns]].name);
	end
end

function api:add_iq_handler(origin_type, xmlns, handler)
	if not (origin_type and handler and xmlns) then return false; end
	if type(origin_type) == "table" then
		for _, origin_type in ipairs(origin_type) do
			_add_iq_handler(self, origin_type, xmlns, handler);
		end
		return;
	end
	_add_iq_handler(self, origin_type, xmlns, handler);
end

function api:add_feature(xmlns)
	addDiscoInfoHandler(self.host, function(reply, to, from, node)
		if #node == 0 then
			reply:tag("feature", {var = xmlns}):up();
			return true;
		end
	end);
end

function api:add_event_hook (...) return eventmanager.add_event_hook(...); end

local function _add_handler(module, origin_type, tag, xmlns, handler)
	local handlers = stanza_handlers[module.host];
	handlers[origin_type] = handlers[origin_type] or {};
	if not handlers[origin_type][tag] then
		handlers[origin_type][tag] = handlers[origin_type][tag] or {};
		handlers[origin_type][tag][xmlns]= handler;
		handler_info[handler] = module;
		module:log("debug", "I now handle tag '%s' [%s] with xmlns '%s'", tag, origin_type, xmlns);
	elseif handler_info[handlers[origin_type][tag]] then
		log("warning", "I wanted to handle tag '%s' [%s] but mod_%s already handles that", tag, origin_type, handler_info[handlers[origin_type][tag]].module.name);
	end
end

function api:add_handler(origin_type, tag, xmlns, handler)
	if not (origin_type and tag and xmlns and handler) then return false; end
	if type(origin_type) == "table" then
		for _, origin_type in ipairs(origin_type) do
			_add_handler(self, origin_type, tag, xmlns, handler);
		end
		return;
	end
	_add_handler(self, origin_type, tag, xmlns, handler);
end

--------------------------------------------------------------------

return _M;
