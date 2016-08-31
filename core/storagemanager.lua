
local type, pairs = type, pairs;
local setmetatable = setmetatable;

local config = require "core.configmanager";
local datamanager = require "util.datamanager";
local modulemanager = require "core.modulemanager";
local multitable = require "util.multitable";
local hosts = hosts;
local log = require "util.logger".init("storagemanager");

local prosody = prosody;

local _ENV = nil;

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

local stores_available = multitable.new();

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
		log("error", "The temporary 'sql2' storage module has now been renamed to 'sql', please update your config file: https://prosody.im/doc/modules/mod_storage_sql2");
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
	};
}

local open;

local function create_map_shim(host, store)
	local keyval_store, err = open(host, store, "keyval");
	if keyval_store == nil then return nil, err end
	return setmetatable({
		keyval_store = keyval_store;
	}, map_shim_mt);
end

function open(host, store, typ)
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
					log("warn", "Storage driver %s does not support removing all user data, you may need to delete it manually", driver_name);
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
