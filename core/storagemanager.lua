
local error, type = error, type;
local setmetatable = setmetatable;

local config = require "core.configmanager";
local datamanager = require "util.datamanager";
local modulemanager = require "core.modulemanager";
local multitable = require "util.multitable";
local hosts = hosts;
local log = require "util.logger".init("storagemanager");

local olddm = {}; -- maintain old datamanager, for backwards compatibility
for k,v in pairs(datamanager) do olddm[k] = v; end
local prosody = prosody;

module("storagemanager")

local default_driver_mt = { name = "internal" };
default_driver_mt.__index = default_driver_mt;
function default_driver_mt:open(store)
	return setmetatable({ host = self.host, store = store }, default_driver_mt);
end
function default_driver_mt:get(user) return olddm.load(user, self.host, self.store); end
function default_driver_mt:set(user, data) return olddm.store(user, self.host, self.store, data); end

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

local function load_driver(host, driver_name)
	if not driver_name then
		return;
	end
	local driver = stores_available:get(host, driver_name);
	if driver then return driver; end
	if driver_name ~= "internal" then
		local ok, err = modulemanager.load(host, "storage_"..driver_name);
		if not ok then
			log("error", "Failed to load storage driver plugin %s on %s: %s", driver_name, host, err);
		end
		return stores_available:get(host, driver_name);
	else
		return setmetatable({host = host}, default_driver_mt);
	end
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
	
	local driver = load_driver(host, driver_name);
	if not driver then
		driver_name = config.get(host, "core", "default_storage");
		driver = load_driver(host, driver_name);
		if not driver then
			if driver_name or (type(storage) == "string"
			or type(storage) == "table" and storage[store]) then
				log("warn", "Falling back to default driver for %s storage on %s", store, host);
			end
			driver_name = "internal";
			driver = load_driver(host, driver_name);
		end
	end
	
	local ret, err = driver:open(store, typ);
	if not ret then
		if err == "unsupported-store" then
			log("debug", "Storage driver %s does not support store %s (%s), falling back to internal driver",
				driver_name, store, typ);
			ret = setmetatable({ host = host, store = store }, default_driver_mt); -- default to default driver
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
