
local error, type, pairs = error, type, pairs;
local setmetatable = setmetatable;

local config = require "core.configmanager";
local datamanager = require "util.datamanager";
local modulemanager = require "core.modulemanager";
local multitable = require "util.multitable";
local hosts = hosts;
local log = require "util.logger".init("storagemanager");

local prosody = prosody;

module("storagemanager")

local olddm = {}; -- maintain old datamanager, for backwards compatibility
for k,v in pairs(datamanager) do olddm[k] = v; end
_M.olddm = olddm;

local null_storage_method = function () return false, "no data storage active"; end
local null_storage_driver = setmetatable(
	{
		name = "null",
		open = function (self) return self; end
	}, {
		__index = function (self, method)
			return null_storage_method;
		end
	}
);

local stores_available = multitable.new();

function initialize_host(host)
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

function load_driver(host, driver_name)
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

function get_driver(host, store)
	local storage = config.get(host, "storage");
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
			if ret == nil and err then return nil, err end
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
	};
}
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
				return create_map_shim(host, store);
			end
			log("debug", "Storage driver %s does not support store %s (%s), falling back to null driver",
				driver_name, store, typ or "<nil>");
			ret = null_storage_driver;
			err = nil;
		end
	end
	return ret, err;
end

function purge(user, host)
	local storage = config.get(host, "storage");
	if type(storage) == "table" then
		-- multiple storage backends in use that we need to purge
		local purged = {};
		for store, driver in pairs(storage) do
			if not purged[driver] then
				purged[driver] = get_driver(host, store):purge(user);
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
		return function() log("warn", "storage driver %s does not support listing users", driver.name) end
	end
	return driver:users();
end
function datamanager.stores(username, host, typ)
	return get_driver(host):stores(username, typ);
end
function datamanager.purge(username, host)
	return purge(username, host);
end

return _M;
