-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

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

-- Return the first n items an iterator returns
function head(n, f, s, var)
	local c = 0;
	return function (s, var)
		if c >= n then
			return nil;
		end
		c = c + 1;
		return f(s, var);
	end, s;
end

-- Skip the first n items an iterator returns
function skip(n, f, s, var)
	for i=1,n do
		var = f(s, var);
	end
	return f, s, var;
end

-- Return the last n items an iterator returns
function tail(n, f, s, var)
	local results, count = {}, 0;
	while true do
		local ret = { f(s, var) };
		var = ret[1];
	        if var == nil then break; end
		results[(count%n)+1] = ret;
		count = count + 1;
	end

	if n > count then n = count; end

	local pos = 0;
	return function ()
		pos = pos + 1;
		if pos > n then return nil; end
		return unpack(results[((count-1+pos)%n)+1]);
	end
	--return reverse(head(n, reverse(f, s, var)));
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
