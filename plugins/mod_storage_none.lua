local driver = {};
local driver_mt = { __index = driver };

function driver:open(store)
	return setmetatable({ store = store }, driver_mt);
end
function driver:get(user)
	return {};
end

function driver:set(user, data)
	return nil, "Storage disabled";
end

function driver:stores(username)
	return { "roster" };
end

function driver:purge(user)
	return true;
end

module:provides("storage", driver);
