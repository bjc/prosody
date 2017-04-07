-- luacheck: ignore 212

local driver = {};
local driver_mt = { __index = driver };

function driver:open(store, typ)
	if typ and typ ~= "keyval" and typ ~= "archive" then
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

function driver:append()
	return nil, "Storage disabled";
end

function driver:find()
	return function () end, 0;
end

function driver:delete()
	return true;
end

module:provides("storage", driver);
