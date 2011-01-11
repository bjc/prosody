
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
	host_session.events.add_handler("item-added/data-driver", function (event)
		local item = event.item;
		stores_available:set(host, item.name, item);
	end);
	
	host_session.events.add_handler("item-removed/data-driver", function (event)
		local item = event.item;
		stores_available:set(host, item.name, nil);
	end);
end
prosody.events.add_handler("host-activated", initialize_host, 101);

function load_driver(host, driver_name)
	if driver_name == "null" then
		return null_storage_provider;
	end
	local driver = stores_available:get(host, driver_name);
	if driver then return driver; end
	local ok, err = modulemanager.load(host, "storage_"..driver_name);
	if not ok then
		log("error", "Failed to load storage driver plugin %s on %s: %s", driver_name, host, err);
	end
	return stores_available:get(host, driver_name);
end

function open(host, store, typ)
	local storage = config.get(host, "core", "storage");
	local driver_name;
	local option_type = type(storage);
	if option_type == "string" then
		driver_name = storage;
	elseif option_type == "table" then
		driver_name = storage[store];
	end
	if not driver_name then
		driver_name = config.get(host, "core", "default_storage") or "internal";
	end
	
	local driver = load_driver(host, driver_name);
	if not driver then
		log("warn", "Falling back to null driver for %s storage on %s", store, host);
		driver_name = "null";
		driver = null_storage_driver;
	end
	
	local ret, err = driver:open(store, typ);
	if not ret then
		if err == "unsupported-store" then
			log("debug", "Storage driver %s does not support store %s (%s), falling back to null driver",
				driver_name, store, typ);
			ret = null_storage_driver;
			err = nil;
		end
	end
	return ret, err;
end

function datamanager.load(username, host, datastore)
	return open(host, datastore):get(username);
end
function datamanager.store(username, host, datastore, data)
	return open(host, datastore):set(username, data);
end

return _M;
