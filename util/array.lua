local array_methods = {};
local array_mt = { __index = array_methods, __tostring = function (array) return array:concat(", "); end };

local function array(t)
	return setmetatable(t or {}, array_mt);
end

function array_methods:map(func, t2)
	local t2 = t2 or array{};
	for k,v in ipairs(self) do
		t2[k] = func(v);
	end
	return t2;
end

function array_methods:filter(func, t2)
	local t2 = t2 or array{};
	for k,v in ipairs(self) do
		if func(v) then
			t2:push(v);
		end
	end
	return t2;
end


array_methods.push = table.insert;
array_methods.pop = table.remove;
array_methods.sort = table.sort;
array_methods.concat = table.concat;
array_methods.length = function (t) return #t; end

function array_methods:random()
	return self[math.random(1,#self)];
end

function array_methods:shuffle()
	local len = #self;
	for i=1,#self do
		local r = math.random(i,len);
		self[i], self[r] = self[r], self[i];
	end
end

_G.array = array 
