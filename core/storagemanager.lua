
local error = error;
local setmetatable = setmetatable;

local config = require "core.configmanager";
local datamanager = require "util.datamanager";
local multitable = require "util.multitable";
local modulemanager = require "core.modulemanager";
local hosts = hosts;
local log = require "util.logger".init("storagemanager");

local olddm = {}; -- maintain old datamanager, for backwards compatibility
for k,v in pairs(datamanager) do olddm[k] = v; end

local driver_cache = multitable.new();
local store_cache = multitable.new();

module("storagemanager")

local default_driver_mt = {};
default_driver_mt.__index = default_driver_mt;
function default_driver_mt:open(store)
	return setmetatable({ host = self.host, store = store }, default_driver_mt);
end
function default_driver_mt:get(user) return olddm.load(user, self.host, self.store); end
function default_driver_mt:set(user, data) return olddm.store(user, self.host, self.store, data); end

local function load_driver_for_host(host)
	if driver_cache:get(host) then return driver_cache:get(host); end
	
	local host_session = hosts[host];
	if not host_session then error("No such host"); end
	
	local driver_plugin = config.get(host, "core", "datastore");
	if not driver_plugin then return setmetatable({ host = host }, default_driver_mt); end
	
	local provider;
	local function handler(event) provider = event.item; end
	host_session.events.add_handler("item-added/data-driver", handler);
	local success, err = modulemanager.load(host, driver_plugin);
	host_session.events.remove_handler("item-added/data-driver", handler);
	if not success then error(err); end
	if not provider then error("Module didn't add a provider"); end
	
	driver_cache:set(host, provider);
	log("debug", "Data driver '%s' loaded for host '%s'", driver_plugin, host);
	return provider;
end

function open(host, store, typ)
	local ret = store_cache:get(host, store);
	if not ret then
		local driver = load_driver_for_host(host);
		ret = driver:open(store, typ);
		if not ret then ret = setmetatable({ host = host, store = store }, default_driver_mt); end -- default to default driver
		store_cache:set(host, store, ret);
	end
	return ret;
end

function datamanager.load(username, host, datastore)
	return open(host, datastore):get(username);
end
function datamanager.store(username, host, datastore, data)
	return open(host, datastore):set(username, data);
end

return _M;
