-- Prosody IM
-- Copyright (C) 2008-2012 Matthew Wild
-- Copyright (C) 2008-2012 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local array = require "prosody.util.array";
local set = require "prosody.util.set";
local it = require "prosody.util.iterators";
local logger = require "prosody.util.logger";
local timer = require "prosody.util.timer";
local resolve_relative_path = require"prosody.util.paths".resolve_relative_path;
local st = require "prosody.util.stanza";
local cache = require "prosody.util.cache";
local errors = require "prosody.util.error";
local promise = require "prosody.util.promise";
local time_now = require "prosody.util.time".now;
local format = require "prosody.util.format".format;
local jid_node = require "prosody.util.jid".node;
local jid_split = require "prosody.util.jid".split;
local jid_resource = require "prosody.util.jid".resource;
local human_io = require "prosody.util.human.io";

local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;
local error, setmetatable, type = error, setmetatable, type;
local ipairs, pairs, select = ipairs, pairs, select;
local tonumber, tostring = tonumber, tostring;
local require = require;
local pack = table.pack;
local unpack = table.unpack;

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
		self:log("warn", "Error: Insufficient parameters to module:hook_tag()");
		return;
	end
	return self:hook("stanza/"..(xmlns and (xmlns..":") or "")..name,
		function (data) return handler(data.origin, data.stanza, data); end, priority);
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
	local modulemanager = require"prosody.core.modulemanager";
	local f, n = modulemanager.loader:load_code_ext(self.name, lib, "lib.lua", self.environment);
	if not f then error("Failed to load plugin library '"..lib.."', error: "..n); end -- FIXME better error message
	return f();
end

function api:depends(name, soft)
	local modulemanager = require"prosody.core.modulemanager";
	if self:get_option_inherited_set("modules_disabled", {}):contains(name) then
		if not soft then
			error("Dependency on disabled module mod_"..name);
		end
		self:log("debug", "Not loading disabled soft dependency mod_%s", name);
		return nil, "disabled";
	end
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
	if not mod.module.reverse_dependencies then
		mod.module.reverse_dependencies = {};
	end
	mod.module.reverse_dependencies[self.name] = true;
	return mod;
end

local function get_shared_table_from_path(module, tables, path)
	if path:sub(1,1) ~= "/" then -- Prepend default components
		local default_path_components = { module.host, module.name };
		local n_components = select(2, path:gsub("/", "%1"));
		path = (n_components<#default_path_components and "/" or "")
			..t_concat(default_path_components, "/", 1, #default_path_components-n_components).."/"..path;
	end
	local shared = tables[path];
	if not shared then
		shared = {};
		if path:match("%-cache$") then
			setmetatable(shared, { __mode = "kv" });
		end
		tables[path] = shared;
	end
	return shared;
end

-- Returns a shared table at the specified virtual path
-- Intentionally does not allow the table to be _set_, it
-- is auto-created if it does not exist.
function api:shared(path)
	if not self.shared_data then self.shared_data = {}; end
	local shared = get_shared_table_from_path(self, shared_data, path);
	self.shared_data[path] = shared;
	return shared;
end

function api:get_option(name, default_value)
	local config = require "prosody.core.configmanager";
	local value = config.get(self.host, name);
	if value == nil then
		value = default_value;
	end
	return value;
end

function api:get_option_scalar(name, default_value)
	local value = self:get_option(name, default_value);
	if type(value) == "table" then
		if #value > 1 then
			self:log("error", "Config option '%s' does not take a list, using just the first item", name);
		end
		value = value[1];
	end
	return value;
end

function api:get_option_string(name, default_value)
	local value = self:get_option_scalar(name, default_value);
	if value == nil then
		return nil;
	end
	return tostring(value);
end

function api:get_option_number(name, default_value, min, max)
	local value = self:get_option_scalar(name, default_value);
	local ret = tonumber(value);
	if value ~= nil and ret == nil then
		self:log("error", "Config option '%s' not understood, expecting a number", name);
	end
	if ret == default_value then
		-- skip interval checks for default or nil
		return ret;
	end
	if min and ret < min then
		self:log("warn", "Config option '%s' out of bounds %g < %g", name, ret, min);
		return min;
	end
	if max and ret > max then
		self:log("warn", "Config option '%s' out of bounds %g > %g", name, ret, max);
		return max;
	end
	return ret;
end

function api:get_option_integer(name, default_value, min, max)
	local value = self:get_option_number(name, default_value, min or math.mininteger or -2 ^ 52, max or math.maxinteger or 2 ^ 53);
	if value == default_value then
		-- pass default trough unaltered, violates ranges sometimes
		return value;
	end
	if math.type(value) == "float" then
		self:log("warn", "Config option '%s' expected an integer, not a float (%g)", name, value)
		return math.floor(value);
	end
	-- nil or an integer
	return value;
end

function api:get_option_period(name, default_value, min, max)
	local value = self:get_option_scalar(name, default_value);

	local ret;
	if value == "never" or value == false then
		-- usually for disabling some periodic thing
		return math.huge;
	elseif type(value) == "number" then
		-- assume seconds
		ret = value;
	elseif type(value) == "string" then
		ret = human_io.parse_duration(value);
		if value ~= nil and ret == nil then
			ret = human_io.parse_duration_lax(value);
			if ret then
				local num = value:match("%d+");
				self:log("error", "Config option '%s' is set to ambiguous period '%s' - use full syntax e.g. '%s months' or '%s minutes'", name, value, num, num);
				-- COMPAT: w/more relaxed behaviour in post-0.12 trunk. Return nil for this case too, eventually.
			else
				self:log("error", "Config option '%s' not understood, expecting a period (e.g. \"2 days\")", name);
				return nil;
			end
		end
	elseif value ~= nil then
		self:log("error", "Config option '%s' expects a number or a period description string (e.g. \"3 hours\"), not %s", name, type(value));
		return nil;
	else
		return nil;
	end

	if ret < 0 then
		self:log("debug", "Treating negative period as infinity");
		return math.huge;
	end

	if type(min) == "string" then
		min = human_io.parse_duration(min);
	end
	if min and ret < min then
		self:log("warn", "Config option '%s' out of bounds %g < %g", name, ret, min);
		return min;
	end
	if type(max) == "string" then
		max = human_io.parse_duration(max);
	end
	if max and ret > max then
		self:log("warn", "Config option '%s' out of bounds %g > %g", name, ret, max);
		return max;
	end

	return ret;
end

function api:get_option_boolean(name, ...)
	local value = self:get_option_scalar(name, ...);
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

function api:get_option_path(name, default, parent)
	if parent == nil then
		parent = self:get_directory();
	elseif prosody.paths[parent] then
		parent = prosody.paths[parent];
	end
	local value = self:get_option_string(name, default);
	if value == nil then
		return nil;
	end
	return resolve_relative_path(parent, value);
end

function api:get_option_enum(name, default, ...)
	local value = self:get_option_scalar(name, default);
	if value == nil then return nil; end
	local options = set.new{default, ...};
	if not options:contains(value) then
		self:log("error", "Config option '%s' not in set of allowed values (one of: %s)", name, options);
	end
	return value;
end

function api:context(host)
	return setmetatable({ host = host or "*", global = "*" == host }, { __index = self, __newindex = self });
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
	local modulemanager = require"prosody.core.modulemanager";
	local result = modulemanager.get_items(key, self.host) or {};
	return result;
end

function api:handle_items(item_type, added_cb, removed_cb, existing)
	self:hook("item-added/"..item_type, added_cb);
	self:hook("item-removed/"..item_type, removed_cb);
	if existing ~= false then
		local modulemanager = require"prosody.core.modulemanager";
		local modules = modulemanager.get_modules(self.host);

		for _, module in pairs(modules) do
			local mod = module.module;
			if mod.items and mod.items[item_type] then
				for _, item in ipairs(mod.items[item_type]) do
					added_cb({ source = mod; item = item });
				end
			end
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
		if item_name:find((name:gsub("%-", "_")).."_", 1, true) == 1 then
			item_name = item_name:sub(#name+2);
		end
		item.name = item_name;
	end
	item._provided_by = self.name;
	self:add_item(name.."-provider", item);
end

function api:send(stanza, origin)
	return core_post_stanza(origin or hosts[self.host], stanza);
end

function api:send_iq(stanza, origin, timeout)
	local iq_cache = self._iq_cache;
	if not iq_cache then
		iq_cache = cache.new(256, function (_, iq)
			iq.reject(errors.new({
				type = "wait", condition = "resource-constraint",
				text = "evicted from iq tracking cache"
			}));
		end);
		self._iq_cache = iq_cache;
	end

	local event_type;
	if not jid_node(stanza.attr.from) then
		event_type = "host";
	elseif jid_resource(stanza.attr.from) then
		event_type = "full";
	else -- assume bare since we can't hook full jids
		event_type = "bare";
	end
	local result_event = "iq-result/"..event_type.."/"..stanza.attr.id;
	local error_event = "iq-error/"..event_type.."/"..stanza.attr.id;
	local cache_key = event_type.."/"..stanza.attr.id;
	if event_type == "full" then
		result_event = "iq/" .. event_type;
		error_event = "iq/" .. event_type;
	end

	local p = promise.new(function (resolve, reject)
		local function result_handler(event)
			local response = event.stanza;
			if response.attr.type == "result" and response.attr.from == stanza.attr.to and response.attr.id == stanza.attr.id then
				resolve(event);
				return true;
			end
		end

		local function error_handler(event)
			local response = event.stanza;
			if response.attr.type == "error" and response.attr.from == stanza.attr.to and response.attr.id == stanza.attr.id then
				reject(errors.from_stanza(event.stanza, event));
				return true;
			end
		end

		if iq_cache:get(cache_key) then
			reject(errors.new({
				type = "modify", condition = "conflict",
				text = "IQ stanza id attribute already used",
			}));
			return;
		end

		self:hook(result_event, result_handler, 1);
		self:hook(error_event, error_handler, 1);

		local timeout_handle = self:add_timer(timeout or 120, function ()
			reject(errors.new({
				type = "wait", condition = "remote-server-timeout",
				text = "IQ stanza timed out",
			}));
		end);

		local ok = iq_cache:set(cache_key, {
			reject = reject, resolve = resolve,
			timeout_handle = timeout_handle,
			result_handler = result_handler, error_handler = error_handler;
		});

		if not ok then
			reject(errors.new({
				type = "wait", condition = "internal-server-error",
				text = "Could not store IQ tracking data"
			}));
			return;
		end

		local wrapped_origin = setmetatable({
				-- XXX Needed in some cases for replies to work correctly when sending queries internally.
				send = function (reply)
					if reply.name == stanza.name and reply.attr.id == stanza.attr.id then
						resolve({ stanza = reply });
					end
					return (origin or hosts[self.host]).send(reply)
				end;
			}, {
				__index = origin or hosts[self.host];
			});

		self:send(stanza, wrapped_origin);
	end);

	p:finally(function ()
		local iq = iq_cache:get(cache_key);
		if iq then
			self:unhook(result_event, iq.result_handler);
			self:unhook(error_event, iq.error_handler);
			iq.timeout_handle:stop();
			iq_cache:set(cache_key, nil);
		end
	end);

	return p;
end

function api:broadcast(jids, stanza, iter)
	for jid in (iter or it.values)(jids) do
		local new_stanza = st.clone(stanza);
		new_stanza.attr.to = jid;
		self:send(new_stanza);
	end
end

local timer_methods = { }
local timer_mt = {
	__index = timer_methods;
}
function timer_methods:stop( )
	timer.stop(self.id);
end
timer_methods.disarm = timer_methods.stop
function timer_methods:reschedule(delay)
	timer.reschedule(self.id, delay)
end

local function timer_callback(now, id, t) --luacheck: ignore 212/id
	if t.module_env.loaded == false then return; end
	return t.callback(now, unpack(t, 1, t.n));
end

function api:add_timer(delay, callback, ...)
	local t = pack(...)
	t.module_env = self;
	t.callback = callback;
	t.id = timer.add_task(delay, timer_callback, t);
	return setmetatable(t, timer_mt);
end

function api:cron(task_spec)
	self:depends("cron");
	self:add_item("task", task_spec);
end

function api:hourly(name, fun)
	if type(name) == "function" then fun, name = name, nil; end
	self:cron({ name = name; when = "hourly"; run = fun });
end

function api:daily(name, fun)
	if type(name) == "function" then fun, name = name, nil; end
	self:cron({ name = name; when = "daily"; run = fun });
end

function api:weekly(name, fun)
	if type(name) == "function" then fun, name = name, nil; end
	self:cron({ name = name; when = "weekly"; run = fun });
end

local path_sep = package.config:sub(1,1);
function api:get_directory()
	return self.resource_path or self.path and (self.path:gsub("%"..path_sep.."[^"..path_sep.."]*$", "")) or nil;
end

function api:load_resource(path, mode)
	path = resolve_relative_path(self:get_directory(), path);
	return io.open(path, mode);
end

function api:open_store(name, store_type)
	if self.host == "*" then return nil, "global-storage-not-supported"; end
	return require"prosody.core.storagemanager".open(self.host, name or self.name, store_type);
end

function api:measure(name, stat_type, conf)
	local measure = require "prosody.core.statsmanager".measure;
	local fixed_label_key, fixed_label_value
	if self.host ~= "*" then
		fixed_label_key = "host"
		fixed_label_value = self.host
	end
	-- new_legacy_metric takes care of scoping for us, as it does not accept
	-- an array of labels
	-- the prosody_ prefix is automatically added by statsmanager for legacy
	-- metrics.
	self:add_item("measure", { name = name, type = stat_type, conf = conf });
	return measure(stat_type, "mod_"..self.name.."/"..name, conf, fixed_label_key, fixed_label_value)
end

function api:metric(type_, name, unit, description, label_keys, conf)
	local metric = require "prosody.core.statsmanager".metric;
	local is_scoped = self.host ~= "*"
	label_keys = label_keys or {};
	if is_scoped then
		-- prepend `host` label to label keys if this is not a global module
		local orig_labels = label_keys
		label_keys = array { "host" }
		label_keys:append(orig_labels)
	end
	local mf = metric(type_, "prosody_mod_"..self.name.."/"..name, unit, description, label_keys, conf)
	self:add_item("metric", { name = name, mf = mf });
	if is_scoped then
		-- make sure to scope the returned metric family to the current host
		return mf:with_partial_label(self.host)
	end
	return mf
end

local status_priorities = { error = 3, warn = 2, info = 1, core = 0 };

function api:set_status(status_type, status_message, override)
	local priority = status_priorities[status_type];
	if not priority then
		self:log("error", "set_status: Invalid status type '%s', assuming 'info'", status_type);
		status_type, priority = "info", status_priorities.info;
	end
	local current_priority = status_priorities[self.status_type] or 0;
	-- By default an 'error' status can only be overwritten by another 'error' status
	if (current_priority >= status_priorities.error and priority < current_priority and override ~= true)
	or (override == false and current_priority > priority) then
		self:log("debug", "moduleapi: ignoring status [prio %d override %s]: %s", priority, override, status_message);
		return;
	end
	self.status_type, self.status_message, self.status_time = status_type, status_message, time_now();
	self:fire_event("module-status/updated", { name = self.name });
end

function api:log_status(level, msg, ...)
	self:set_status(level, format(msg, ...));
	return self:log(level, msg, ...);
end

function api:get_status()
	return self.status_type, self.status_message, self.status_time;
end

function api:default_permission(role_name, permission)
	permission = permission:gsub("^:", self.name..":");
	if self.host == "*" then
		for _, host in pairs(hosts) do
			if host.authz then
				host.authz.add_default_permission(role_name, permission);
			end
		end
		return
	end
	hosts[self.host].authz.add_default_permission(role_name, permission);
end

function api:default_permissions(role_name, permissions)
	for _, permission in ipairs(permissions) do
		self:default_permission(role_name, permission);
	end
end

function api:could(action, context)
	return self:may(action, context, true);
end

function api:may(action, context, peek)
	if action:byte(1) == 58 then -- action begins with ':'
		action = self.name..action; -- prepend module name
	end

	do
		-- JID-based actor
		local actor_jid = type(context) == "string" and context or context.actor_jid;
		if actor_jid then -- check JID permissions
			local role;
			local node, host = jid_split(actor_jid);
			if host == self.host then
				role = hosts[host].authz.get_user_role(node);
			else
				role = hosts[self.host].authz.get_jid_role(actor_jid);
			end
			if not role then
				if not peek then
					self:log("debug", "Access denied: JID <%s> may not %s (no role found)", actor_jid, action);
				end
				return false;
			end
			local permit = role:may(action);
			if not permit then
				if not peek then
					self:log("debug", "Access denied: JID <%s> may not %s (not permitted by role %s)", actor_jid, action, role.name);
				end
			end
			return permit;
		end
	end

	-- Session-based actor
	local session = context.origin or context.session;
	if type(session) ~= "table" then
		error("Unable to identify actor session from context");
	end
	if session.type == "c2s" and session.host == self.host then
		local role = session.role;
		if not role then
			if not peek then
				self:log("warn", "Access denied: session %s has no role assigned");
			end
			return false;
		end
		local permit = role:may(action, context);
		if not permit and not peek then
			self:log("debug", "Access denied: session %s (%s) may not %s (not permitted by role %s)",
				session.id, session.full_jid, action, role.name
			);
		end
		return permit;
	else
		local actor_jid = context.stanza.attr.from;
		local role = hosts[self.host].authz.get_jid_role(actor_jid);
		if not role then
			if not peek then
				self:log("debug", "Access denied: JID <%s> may not %s (no role found)", actor_jid, action);
			end
			return false;
		end
		local permit = role:may(action, context);
		if not permit and not peek then
			self:log("debug", "Access denied: JID <%s> may not %s (not permitted by role %s)", actor_jid, action, role.name);
		end
		return permit;
	end
end

-- Execute a function, once, but only after startup is complete
function api:on_ready(f) --luacheck: ignore 212/self
	return prosody.started:next(f);
end

-- COMPAT w/post 0.12 trunk
function api:once(f)
	self:log("warn", "This module uses deprecated module:once() - switch to module:on_ready() or (better) expose function module.ready()");
	return self:on_ready(f);
end

return api;
