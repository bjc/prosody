local driver = {};
local driver_mt = { __index = driver };

function driver:open(store, typ)
	if typ and typ ~= "keyval" then
		return nil, "unsupported-store";
	end
	return setmetatable({ store = store, type = typ }, driver_mt);
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
