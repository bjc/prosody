-- Enables SQL query logging
--
-- luacheck: ignore 213/uri

local engines = module:shared("/*/sql/connections");

for uri, engine in pairs(engines) do
	engine:debug(true);
end

setmetatable(engines, {
	__newindex = function (t, uri, engine)
		engine:debug(true);
		rawset(t, uri, engine);
	end
});

function module.unload()
	setmetatable(engines, nil);
	for uri, engine in pairs(engines) do
		engine:debug(false);
	end
end


