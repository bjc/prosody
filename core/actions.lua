
local actions = {};

function register(path, t)
	local curr = actions;
	for comp in path:gmatch("([^/]+)/") do
		if curr[comp] == nil then
			curr[comp] = {};
		end
		curr = curr[comp];
		if type(curr) ~= "table" then
			return nil, "path-taken";
		end
	end
	curr[path:match("/([^/]+)$")] = t;
	return true;
end

return { actions = actions, register= register };