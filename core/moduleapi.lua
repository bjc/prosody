-- Prosody IM
-- Copyright (C) 2008-2012 Matthew Wild
-- Copyright (C) 2008-2012 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local config = require "core.configmanager";
local modulemanager = require "modulemanager";
local array = require "util.array";
local set = require "util.set";
local logger = require "util.logger";
local pluginloader = require "util.pluginloader";

local multitable_new = require "util.multitable".new;

local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;
local error, setmetatable, setfenv, type = error, setmetatable, setfenv, type;
local ipairs, pairs, select, unpack = ipairs, pairs, select, unpack;
local tonumber, tostring = tonumber, tostring;

local prosody = prosody;
local hosts = prosody.hosts;

-- Registry of shared module data
local shared_data = setmetatable({}, { __mode = "v" });

local NULL = {};

local api = {};

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
	-- Update the logger
	local _log = logger.init("mod_"..self.name);
	self.log = function (self, ...) return _log(...); end;
	self._log = _log;
	self.global = true;
end

function api:add_feature(xmlns)
	self:add_item("feature", xmlns);
end
function api:add_identity(category, type, name)
	self:add_item("identity", {category = category, type = type, name = name});
end
function api:add_extension(data)
	self:add_item("extension", data);
end

function api:fire_event(...)
	return (hosts[self.host] or prosody).events.fire_event(...);
end

function api:hook_object_event(object, event, handler, priority)
	self.event_handlers[handler] = { name = event, priority = priority, object = object };
	return object.add_handler(event, handler, priority);
end

function api:hook(event, handler, priority)
	return self:hook_object_event((hosts[self.host] or prosody).events, event, handler, priority);
end

function api:hook_global(event, handler, priority)
	return self:hook_object_event(prosody.events, event, handler, priority);
end

function api:hook_stanza(xmlns, name, handler, priority)
	if not handler and type(name) == "function" then
		-- If only 2 options then they specified no xmlns
		xmlns, name, handler, priority = nil, xmlns, name, handler;
	elseif not (handler and name) then
		self:log("warn", "Error: Insufficient parameters to module:hook_stanza()");
		return;
	end
	return self:hook("stanza/"..(xmlns and (xmlns..":") or "")..name, function (data) return handler(data.origin, data.stanza, data); end, priority);
end

function api:require(lib)
	local f, n = pluginloader.load_code(self.name, lib..".lib.lua");
	if not f then
		f, n = pluginloader.load_code(lib, lib..".lib.lua");
	end
	if not f then error("Failed to load plugin library '"..lib.."', error: "..n); end -- FIXME better error message
	setfenv(f, self.environment);
	return f();
end

function api:depends(name)
	if not self.dependencies then
		self.dependencies = {};
		self:hook("module-reloaded", function (event)
			if self.dependencies[event.module] then
				self:log("info", "Auto-reloading due to reload of %s:%s", event.host, event.module);
				modulemanager.reload(self.host, self.name);
				return;
			end
		end);
		self:hook("module-unloaded", function (event)
			if self.dependencies[event.module] then
				self:log("info", "Auto-unloading due to unload of %s:%s", event.host, event.module);
				modulemanager.unload(self.host, self.name);
			end
		end);
	end
	local mod = modulemanager.get_module(self.host, name) or modulemanager.get_module("*", name);
	if not mod then
		local err;
		mod, err = modulemanager.load(self.host, name);
		if not mod then
			return error(("Unable to load required module, mod_%s: %s"):format(name, ((err or "unknown error"):gsub("%-", " ")) ));
		end
	end
	self.dependencies[name] = true;
	return mod;
end

-- Returns one or more shared tables at the specified virtual paths
-- Intentionally does not allow the table at a path to be _set_, it
-- is auto-created if it does not exist.
function api:shared(...)
	local paths = { n = select("#", ...), ... };
	local data_array = {};
	local default_path_components = { self.host, self.name };
	for i = 1, paths.n do
		local path = paths[i];
		if path:sub(1,1) ~= "/" then -- Prepend default components
			local n_components = select(2, path:gsub("/", "%1"));
			path = (n_components<#default_path_components and "/" or "")..t_concat(default_path_components, "/", 1, #default_path_components-n_components).."/"..path;
		end
		local shared = shared_data[path];
		if not shared then
			shared = {};
			shared_data[path] = shared;
		end
		t_insert(data_array, shared);
	end
	return unpack(data_array);
end

function api:get_option(name, default_value)
	local value = config.get(self.host, self.name, name);
	if value == nil then
		value = config.get(self.host, "core", name);
		if value == nil then
			value = default_value;
		end
	end
	return value;
end

function api:get_option_string(name, default_value)
	local value = self:get_option(name, default_value);
	if type(value) == "table" then
		if #value > 1 then
			self:log("error", "Config option '%s' does not take a list, using just the first item", name);
		end
		value = value[1];
	end
	if value == nil then
		return nil;
	end
	return tostring(value);
end

function api:get_option_number(name, ...)
	local value = self:get_option(name, ...);
	if type(value) == "table" then
		if #value > 1 then
			self:log("error", "Config option '%s' does not take a list, using just the first item", name);
		end
		value = value[1];
	end
	local ret = tonumber(value);
	if value ~= nil and ret == nil then
		self:log("error", "Config option '%s' not understood, expecting a number", name);
	end
	return ret;
end

function api:get_option_boolean(name, ...)
	local value = self:get_option(name, ...);
	if type(value) == "table" then
		if #value > 1 then
			self:log("error", "Config option '%s' does not take a list, using just the first item", name);
		end
		value = value[1];
	end
	if value == nil then
		return nil;
	end
	local ret = value == true or value == "true" or value == 1 or nil;
	if ret == nil then
		ret = (value == false or value == "false" or value == 0);
		if ret then
			ret = false;
		else
			ret = nil;
		end
	end
	if ret == nil then
		self:log("error", "Config option '%s' not understood, expecting true/false", name);
	end
	return ret;
end

function api:get_option_array(name, ...)
	local value = self:get_option(name, ...);

	if value == nil then
		return nil;
	end
	
	if type(value) ~= "table" then
		return array{ value }; -- Assume any non-list is a single-item list
	end
	
	return array():append(value); -- Clone
end

function api:get_option_set(name, ...)
	local value = self:get_option_array(name, ...);
	
	if value == nil then
		return nil;
	end
	
	return set.new(value);
end

local module_items = multitable_new();
function api:add_item(key, value)
	self.items = self.items or {};
	self.items[key] = self.items[key] or {};
	t_insert(self.items[key], value);
	self:fire_event("item-added/"..key, {source = self, item = value});
end
function api:remove_item(key, value)
	local t = self.items and self.items[key] or NULL;
	for i = #t,1,-1 do
		if t[i] == value then
			t_remove(self.items[key], i);
			self:fire_event("item-removed/"..key, {source = self, item = value});
			return value;
		end
	end
end

function api:get_host_items(key)
	local result = {};
	for mod_name, module in pairs(modulemanager.get_modules(self.host)) do
		module = module.module;
		if module.items then
			for _, item in ipairs(module.items[key] or NULL) do
				t_insert(result, item);
			end
		end
	end
	for mod_name, module in pairs(modulemanager.get_modules("*")) do
		module = module.module;
		if module.items then
			for _, item in ipairs(module.items[key] or NULL) do
				t_insert(result, item);
			end
		end
	end
	return result;
end

function api:handle_items(type, added_cb, removed_cb, existing)
	self:hook("item-added/"..type, added_cb);
	self:hook("item-removed/"..type, removed_cb);
	if existing ~= false then
		for _, item in ipairs(self:get_host_items(type)) do
			added_cb({ item = item });
		end
	end
end

function api:provides(name, item)
	if not item then item = self.environment; end
	if not item.name then
		local item_name = module.name;
		-- Strip a provider prefix to find the item name
		-- (e.g. "auth_foo" -> "foo" for an auth provider)
		if item_name:find(name.."_", 1, true) == 1 then
			item_name = item_name:sub(#name+2);
		end
		item.name = item_name;
	end
	self:add_item(name, item);
end

return api;
