-- Prosody IM
-- Copyright (C) 2008-2012 Matthew Wild
-- Copyright (C) 2008-2012 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local config = require "core.configmanager";
local array = require "util.array";
local set = require "util.set";
local it = require "util.iterators";
local logger = require "util.logger";
local pluginloader = require "util.pluginloader";
local timer = require "util.timer";
local resolve_relative_path = require"util.paths".resolve_relative_path;
local measure = require "core.statsmanager".measure;
local st = require "util.stanza";

local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;
local error, setmetatable, type = error, setmetatable, type;
local ipairs, pairs, select, unpack = ipairs, pairs, select, unpack;
local tonumber, tostring = tonumber, tostring;
local require = require;

local prosody = prosody;
local hosts = prosody.hosts;

-- FIXME: This assert() is to try and catch an obscure bug (2013-04-05)
local core_post_stanza = assert(prosody.core_post_stanza,
	"prosody.core_post_stanza is nil, please report this as a bug");

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
	return (self.host == "*" and "global") or hosts[self.host].type or "local";
end

function api:set_global()
	self.host = "*";
	-- Update the logger
	local _log = logger.init("mod_"..self.name);
	self.log = function (self, ...) return _log(...); end; --luacheck: ignore self
	self._log = _log;
	self.global = true;
end

function api:add_feature(xmlns)
	self:add_item("feature", xmlns);
end
function api:add_identity(category, identity_type, name)
	self:add_item("identity", {category = category, type = identity_type, name = name});
end
function api:add_extension(data)
	self:add_item("extension", data);
end
function api:has_feature(xmlns)
	for _, feature in ipairs(self:get_host_items("feature")) do
		if feature == xmlns then return true; end
	end
	return false;
end
function api:has_identity(category, identity_type, name)
	for _, id in ipairs(self:get_host_items("identity")) do
		if id.category == category and id.type == identity_type and id.name == name then
			return true;
		end
	end
	return false;
end

function api:fire_event(...)
	return (hosts[self.host] or prosody).events.fire_event(...);
end

function api:hook_object_event(object, event, handler, priority)
	self.event_handlers:set(object, event, handler, true);
	return object.add_handler(event, handler, priority);
end

function api:unhook_object_event(object, event, handler)
	self.event_handlers:set(object, event, handler, nil);
	return object.remove_handler(event, handler);
end

function api:hook(event, handler, priority)
	return self:hook_object_event((hosts[self.host] or prosody).events, event, handler, priority);
end

function api:hook_global(event, handler, priority)
	return self:hook_object_event(prosody.events, event, handler, priority);
end

function api:hook_tag(xmlns, name, handler, priority)
	if not handler and type(name) == "function" then
		-- If only 2 options then they specified no xmlns
		xmlns, name, handler, priority = nil, xmlns, name, handler;
	elseif not (handler and name) then
		self:log("warn", "Error: Insufficient parameters to module:hook_stanza()");
		return;
	end
	return self:hook("stanza/"..(xmlns and (xmlns..":") or "")..name, function (data) return handler(data.origin, data.stanza, data); end, priority);
end
api.hook_stanza = api.hook_tag; -- COMPAT w/pre-0.9

function api:unhook(event, handler)
	return self:unhook_object_event((hosts[self.host] or prosody).events, event, handler);
end

function api:wrap_object_event(events_object, event, handler)
	return self:hook_object_event(assert(events_object.wrappers, "no wrappers"), event, handler);
end

function api:wrap_event(event, handler)
	return self:wrap_object_event((hosts[self.host] or prosody).events, event, handler);
end

function api:wrap_global(event, handler)
	return self:hook_object_event(prosody.events, event, handler);
end

function api:require(lib)
	local f, n = pluginloader.load_code(self.name, lib..".lib.lua", self.environment);
	if not f then
		f, n = pluginloader.load_code(lib, lib..".lib.lua", self.environment);
	end
	if not f then error("Failed to load plugin library '"..lib.."', error: "..n); end -- FIXME better error message
	return f();
end

function api:depends(name)
	local modulemanager = require"core.modulemanager";
	if not self.dependencies then
		self.dependencies = {};
		self:hook("module-reloaded", function (event)
			if self.dependencies[event.module] and not self.reloading then
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
	if mod and mod.module.host == "*" and self.host ~= "*"
	and modulemanager.module_has_method(mod, "add_host") then
		mod = nil; -- Target is a shared module, so we still want to load it on our host
	end
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
	if not self.shared_data then self.shared_data = {}; end
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
			if path:match("%-cache$") then
				setmetatable(shared, { __mode = "kv" });
			end
			shared_data[path] = shared;
		end
		t_insert(data_array, shared);
		self.shared_data[path] = shared;
	end
	return unpack(data_array);
end

function api:get_option(name, default_value)
	local value = config.get(self.host, name);
	if value == nil then
		value = default_value;
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

function api:get_option_inherited_set(name, ...)
	local value = self:get_option_set(name, ...);
	local global_value = self:context("*"):get_option_set(name, ...);
	if not value then
		return global_value;
	elseif not global_value then
		return value;
	end
	value:include(global_value);
	return value;
end

function api:context(host)
	return setmetatable({host=host or "*"}, {__index=self,__newindex=self});
end

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
	local modulemanager = require"core.modulemanager";
	local result = modulemanager.get_items(key, self.host) or {};
	return result;
end

function api:handle_items(item_type, added_cb, removed_cb, existing)
	self:hook("item-added/"..item_type, added_cb);
	self:hook("item-removed/"..item_type, removed_cb);
	if existing ~= false then
		for _, item in ipairs(self:get_host_items(item_type)) do
			added_cb({ item = item });
		end
	end
end

function api:provides(name, item)
	-- if not item then item = setmetatable({}, { __index = function(t,k) return rawget(self.environment, k); end }); end
	if not item then
		item = {}
		for k,v in pairs(self.environment) do
			if k ~= "module" then item[k] = v; end
		end
	end
	if not item.name then
		local item_name = self.name;
		-- Strip a provider prefix to find the item name
		-- (e.g. "auth_foo" -> "foo" for an auth provider)
		if item_name:find(name.."_", 1, true) == 1 then
			item_name = item_name:sub(#name+2);
		end
		item.name = item_name;
	end
	item._provided_by = self.name;
	self:add_item(name.."-provider", item);
end

function api:send(stanza)
	return core_post_stanza(hosts[self.host], stanza);
end

function api:broadcast(jids, stanza, iter)
	for jid in (iter or it.values)(jids) do
		local new_stanza = st.clone(stanza);
		new_stanza.attr.to = jid;
		core_post_stanza(hosts[self.host], new_stanza);
	end
end

function api:add_timer(delay, callback)
	return timer.add_task(delay, function (t)
		if self.loaded == false then return; end
		return callback(t);
	end);
end

local path_sep = package.config:sub(1,1);
function api:get_directory()
	return self.path and (self.path:gsub("%"..path_sep.."[^"..path_sep.."]*$", "")) or nil;
end

function api:load_resource(path, mode)
	path = resolve_relative_path(self:get_directory(), path);
	return io.open(path, mode);
end

function api:open_store(name, store_type)
	return require"core.storagemanager".open(self.host, name or self.name, store_type);
end

function api:measure(name, stat_type)
	return measure(stat_type, "/"..self.host.."/mod_"..self.name.."/"..name);
end

function api:measure_object_event(events_object, event_name, stat_name)
	local m = self:measure(stat_name or event_name, "duration");
	local function handler(handlers, _event_name, _event_data)
		local finished = m();
		local ret = handlers(_event_name, _event_data);
		finished();
		return ret;
	end
	return self:hook_object_event(events_object, event_name, handler);
end

function api:measure_event(event_name, stat_name)
	return self:measure_object_event((hosts[self.host] or prosody).events.wrappers, event_name, stat_name);
end

function api:measure_global_event(event_name, stat_name)
	return self:measure_object_event(prosody.events.wrappers, event_name, stat_name);
end

return api;
