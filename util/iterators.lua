--[[ Iterators ]]--

-- Reverse an iterator
function reverse(f, s, var)
	local results = {};

	-- First call the normal iterator
	while true do
		local ret = { f(s, var) };
		var = ret[1];
	        if var == nil then break; end
		table.insert(results, 1, ret);
	end
	
	-- Then return our reverse one
	local i,max = 0, #results;
	return function (results)
			if i<max then
				i = i + 1;
				return unpack(results[i]);
			end
		end, results;
end

-- Iterate only over keys in a table
local function _keys_it(t, key)
	return (next(t, key));
end
function keys(t)
	return _keys_it, t;
end

-- Iterate only over values in a table
function values(t)
	local key, val;
	return function (t)
		key, val = next(t, key);
		return val;
	end, t;
end

-- Given an iterator, iterate only over unique items
function unique(f, s, var)
	local set = {};
	
	return function ()
		while true do
			local ret = { f(s, var) };
			var = ret[1];
		        if var == nil then break; end
		        if not set[var] then
				set[var] = true;
				return var;
			end
		end
	end;
end

--[[ Return the number of items an iterator returns ]]--
function count(f, s, var)
	local x = 0;
	
	while true do
		local ret = { f(s, var) };
		var = ret[1];
	        if var == nil then break; end
		x = x + 1;
	end	
	
	return x;
end

-- Convert the values returned by an iterator to an array
function it2array(f, s, var)
	local t, var = {};
	while true do
		var = f(s, var);
	        if var == nil then break; end
		table.insert(t, var);
	end
	return t;
end

-- Treat the return of an iterator as key,value pairs, 
-- and build a table
function it2table(f, s, var)
	local t, var = {};
	while true do
		var, var2 = f(s, var);
	        if var == nil then break; end
		t[var] = var2;
	end
	return t;
end
