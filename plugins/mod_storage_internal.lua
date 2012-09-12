local datamanager = require "core.storagemanager".olddm;

local host = module.host;

local driver = {};
local driver_mt = { __index = driver };

function driver:open(store)
	return setmetatable({ store = store }, driver_mt);
end
function driver:get(user)
	return datamanager.load(user, host, self.store);
end

function driver:set(user, data)
	return datamanager.store(user, host, self.store, data);
end

function driver:list_stores(username)
	return datamanager.list_stores(username, host);
end

function driver:purge(user)
	return datamanager.purge(user, host);
end

module:provides("storage", driver);
