
local type, pairs = type, pairs;
local setmetatable = setmetatable;
local rawset = rawset;

local config = require "core.configmanager";
local datamanager = require "util.datamanager";
local modulemanager = require "core.modulemanager";
local multitable = require "util.multitable";
local log = require "util.logger".init("storagemanager");
local async = require "util.async";
local debug = debug;

local prosody = prosody;
local hosts = prosody.hosts;

local _ENV = nil;
-- luacheck: std none

local olddm = {}; -- maintain old datamanager, for backwards compatibility
for k,v in pairs(datamanager) do olddm[k] = v; end

local null_storage_method = function () return false, "no data storage active"; end
local null_storage_driver = setmetatable(
	{
		name = "null",
		open = function (self) return self; end
	}, {
		__index = function (self, method) --luacheck: ignore 212
			return null_storage_method;
		end
	}
);

local async_check = config.get("*", "storage_async_check") == true;

local stores_available = multitable.new();

local function check_async_wrapper(event)
	local store = event.store;
	event.store = setmetatable({}, {
		__index = function (t, method_name)
			local original_method = store[method_name];
			if type(original_method) ~= "function" then
				if original_method then
					rawset(t, method_name, original_method);
				end
				return original_method;
			end
			local wrapped_method = function (...)
				if not async.ready() then
					log("warn", "ASYNC-01: Attempt to access storage outside async context, "
					  .."see https://prosody.im/doc/developers/async - %s", debug.traceback());
				end
				return original_method(...);
			end
			rawset(t, method_name, wrapped_method);
			return wrapped_method;
		end;
	});
end

local function initialize_host(host)
	local host_session = hosts[host];
	host_session.events.add_handler("item-added/storage-provider", function (event)
		local item = event.item;
		stores_available:set(host, item.name, item);
	end);

	host_session.events.add_handler("item-removed/storage-provider", function (event)
		local item = event.item;
		stores_available:set(host, item.name, nil);
	end);
	if async_check then
		host_session.events.add_handler("store-opened", check_async_wrapper);
	end
end
prosody.events.add_handler("host-activated", initialize_host, 101);

local function load_driver(host, driver_name)
	if driver_name == "null" then
		return null_storage_driver;
	end
	local driver = stores_available:get(host, driver_name);
	if driver then return driver; end
	local ok, err = modulemanager.load(host, "storage_"..driver_name);
	if not ok then
		log("error", "Failed to load storage driver plugin %s on %s: %s", driver_name, host, err);
	end
	return stores_available:get(host, driver_name);
end

local function get_storage_config(host)
	-- COMPAT w/ unreleased Prosody 0.10 and the once-experimental mod_storage_sql2 in peoples' config files
	local storage_config = config.get(host, "storage");
	local found_sql2;
	if storage_config == "sql2" then
		storage_config, found_sql2 = "sql", true;
	elseif type(storage_config) == "table" then
		for store_name, driver_name in pairs(storage_config) do
			if driver_name == "sql2" then
				storage_config[store_name] = "sql";
				found_sql2 = true;
			end
		end
	end
	if found_sql2 then
		log("error", "The temporary 'sql2' storage module has now been renamed to 'sql', "
			.."please update your config file: https://prosody.im/doc/modules/mod_storage_sql2");
	end
	return storage_config;
end

local function get_driver(host, store)
	local storage = get_storage_config(host);
	local driver_name;
	local option_type = type(storage);
	if option_type == "string" then
		driver_name = storage;
	elseif option_type == "table" then
		driver_name = storage[store];
	end
	if not driver_name then
		driver_name = config.get(host, "default_storage") or "internal";
	end

	local driver = load_driver(host, driver_name);
	if not driver then
		log("warn", "Falling back to null driver for %s storage on %s", store, host);
		driver_name = "null";
		driver = null_storage_driver;
	end
	return driver, driver_name;
end

local map_shim_mt = {
	__index = {
		get = function(self, username, key)
			local ret, err = self.keyval_store:get(username);
			if ret == nil then return nil, err end
			return ret[key];
		end;
		set = function(self, username, key, data)
			local current, err = self.keyval_store:get(username);
			if current == nil then
				if err then
					return nil, err;
				else
					current = {};
				end
			end
			current[key] = data;
			return self.keyval_store:set(username, current);
		end;
		set_keys = function (self, username, keydatas)
			local current, err = self.keyval_store:get(username);
			if current == nil then
				if err then
					return nil, err;
				end
				current = {};
			end
			for k,v in pairs(keydatas) do
				if v == self.remove then v = nil; end
				current[k] = v;
			end
			return self.keyval_store:set(username, current);
		end;
		remove = {};
		get_all = function (self, key)
			if type(key) ~= "string" or key == "" then
				return nil, "get_all only supports non-empty string keys";
			end
			local ret;
			for username in self.keyval_store:users() do
				local key_data = self:get(username, key);
				if key_data then
					if not ret then
						ret = {};
					end
					ret[username] = key_data;
				end
			end
			return ret;
		end;
		delete_all = function (self, key)
			if type(key) ~= "string" or key == "" then
				return nil, "delete_all only supports non-empty string keys";
			end
			local data = { [key] = self.remove };
			local last_err;
			for username in self.keyval_store:users() do
				local ok, err = self:set_keys(username, data);
				if not ok then
					last_err = err;
				end
			end
			if last_err then
				return nil, last_err;
			end
			return true;
		end;
	};
}

local combined_store_mt = {
	__index = {
		-- keyval
		get = function (self, name)
			return self.keyval_store:get(name);
		end;
		set = function (self, name, data)
			return self.keyval_store:set(name, data);
		end;
		items = function (self)
			return self.keyval_store:users();
		end;
		-- map
		get_key = function (self, name, key)
			return self.map_store:get(name, key);
		end;
		set_key = function (self, name, key, value)
			return self.map_store:set(name, key, value);
		end;
		set_keys = function (self, name, map)
			return self.map_store:set_keys(name, map);
		end;
		get_key_from_all = function (self, key)
			return self.map_store:get_all(key);
		end;
		delete_key_from_all = function (self, key)
			return self.map_store:delete_all(key);
		end;
	};
};

local open; -- forward declaration

local function create_map_shim(host, store)
	local keyval_store, err = open(host, store, "keyval");
	if keyval_store == nil then return nil, err end
	return setmetatable({
		keyval_store = keyval_store;
	}, map_shim_mt);
end

local function open_combined(host, store)
	local driver, driver_name = get_driver(host, store);

	-- Open keyval
	local keyval_store, err = driver:open(store, "keyval");
	if not keyval_store then
		if err == "unsupported-store" then
			log("debug", "Storage driver %s does not support store %s (keyval), falling back to null driver",
				driver_name, store);
			keyval_store, err = null_storage_driver, nil;
		end
	end

	local map_store;
	if keyval_store then
		-- Open map
		map_store, err = driver:open(store, "map");
		if not map_store then
			if err == "unsupported-store" then
				log("debug", "Storage driver %s does not support store %s (map), falling back to shim",
					driver_name, store);
				map_store, err = setmetatable({ keyval_store = keyval_store }, map_shim_mt), nil;
			end
		end
	end

	if not(keyval_store and map_store) then
		return nil, err;
	end
	local combined_store = setmetatable({
		keyval_store = keyval_store;
		map_store = map_store;
		remove = map_store.remove;
	}, combined_store_mt);
	local event_data = { host = host, store_name = store, store_type = "keyval+", store = combined_store };
	hosts[host].events.fire_event("store-opened", event_data);
	return event_data.store, event_data.store_err;
end

function open(host, store, typ)
	if typ == "keyval+" then -- TODO: default in some release?
		return open_combined(host, store);
	end
	local driver, driver_name = get_driver(host, store);
	local ret, err = driver:open(store, typ);
	if not ret then
		if err == "unsupported-store" then
			if typ == "map" then -- Use shim on top of keyval store
				log("debug", "map storage driver unavailable, using shim on top of keyval store.");
				ret, err = create_map_shim(host, store);
			else
				log("debug", "Storage driver %s does not support store %s (%s), falling back to null driver",
					driver_name, store, typ or "<nil>");
				ret, err = null_storage_driver, nil;
			end
		end
	end
	if ret then
		local event_data = { host = host, store_name = store, store_type = typ, store = ret };
		hosts[host].events.fire_event("store-opened", event_data);
		ret, err = event_data.store, event_data.store_err;
	end
	return ret, err;
end

local function purge(user, host)
	local storage = get_storage_config(host);
	if type(storage) == "table" then
		-- multiple storage backends in use that we need to purge
		local purged = {};
		for store, driver_name in pairs(storage) do
			if not purged[driver_name] then
				local driver = get_driver(host, store);
				if driver.purge then
					purged[driver_name] = driver:purge(user);
				else
					log("warn", "Storage driver %s does not support removing all user data, "
						.."you may need to delete it manually", driver_name);
				end
			end
		end
	end
	get_driver(host):purge(user); -- and the default driver

	olddm.purge(user, host); -- COMPAT list stores, like offline messages end up in the old datamanager

	return true;
end

function datamanager.load(username, host, datastore)
	return open(host, datastore):get(username);
end
function datamanager.store(username, host, datastore, data)
	return open(host, datastore):set(username, data);
end
function datamanager.users(host, datastore, typ)
	local driver = open(host, datastore, typ);
	if not driver.users then
		return function() log("warn", "Storage driver %s does not support listing users", driver.name) end
	end
	return driver:users();
end
function datamanager.stores(username, host, typ)
	return get_driver(host):stores(username, typ);
end
function datamanager.purge(username, host)
	return purge(username, host);
end

return {
	initialize_host = initialize_host;
	load_driver = load_driver;
	get_driver = get_driver;
	open = open;
	purge = purge;

	olddm = olddm;
};
