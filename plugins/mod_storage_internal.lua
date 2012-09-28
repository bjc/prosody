local datamanager = require "core.storagemanager".olddm;

local host = module.host;

local driver = {};
local driver_mt = { __index = driver };

function driver:open(store, typ)
	return setmetatable({ store = store, type = typ }, driver_mt);
end
function driver:get(user)
	return datamanager.load(user, host, self.store);
end

function driver:set(user, data)
	return datamanager.store(user, host, self.store, data);
end

function driver:stores(username)
	return datamanager.stores(username, host);
end

function driver:users()
	return datamanager.users(host, self.store, self.type);
end

function driver:purge(user)
	return datamanager.purge(user, host);
end

module:provides("storage", driver);
