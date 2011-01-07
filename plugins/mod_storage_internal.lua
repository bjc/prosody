local datamanager = require "core.storagemanager".olddm;

local host = module.host;

local driver = { name = "internal" };
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

module:add_item("data-driver", driver);
