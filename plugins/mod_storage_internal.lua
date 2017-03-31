local datamanager = require "core.storagemanager".olddm;

local host = module.host;

local driver = {};

function driver:open(store, typ)
	local mt = self[typ or "keyval"]
	if not mt then
		return nil, "unsupported-store";
	end
	return setmetatable({ store = store, type = typ }, mt);
end

function driver:stores(username)
	return datamanager.stores(username, host);
end

function driver:purge(user)
	return datamanager.purge(user, host);
end

local keyval = { };
driver.keyval = { __index = keyval };

function keyval:get(user)
	return datamanager.load(user, host, self.store);
end

function keyval:set(user, data)
	return datamanager.store(user, host, self.store, data);
end

function keyval:users()
	return datamanager.users(host, self.store, self.type);
end

module:provides("storage", driver);
