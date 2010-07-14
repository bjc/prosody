module "roster"

local roster = {};
roster.__index = roster;

function new()
	return setmetatable({}, roster);
end

function roster:subscribers()
end

function roster:subscriptions()
end

function roster:items()
end

return _M;
