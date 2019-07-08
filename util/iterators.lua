-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

--[[ Iterators ]]--

local it = {};

local t_insert = table.insert;
local next = next;
local unpack = table.unpack or unpack; --luacheck: ignore 113
local pack = table.pack or require "util.table".pack;
local type = type;
local table, setmetatable = table, setmetatable;

local _ENV = nil;
--luacheck: std none

-- Reverse an iterator
function it.reverse(f, s, var)
	local results = {};

	-- First call the normal iterator
	while true do
		local ret = { f(s, var) };
		var = ret[1];
		if var == nil then break; end
		t_insert(results, 1, ret);
	end

	-- Then return our reverse one
	local i,max = 0, #results;
	return function (_results)
		if i<max then
			i = i + 1;
			return unpack(_results[i]);
		end
	end, results;
end

-- Iterate only over keys in a table
local function _keys_it(t, key)
	return (next(t, key));
end
function it.keys(t)
	return _keys_it, t;
end

-- Iterate only over values in a table
function it.values(t)
	local key, val;
	return function (_t)
		key, val = next(_t, key);
		return val;
	end, t;
end

-- Iterate over the n:th return value
function it.select(n, f, s, var)
	return function (_s)
		local ret = pack(f(_s, var));
		var = ret[1];
		return ret[n];
	end, s, var;
end

-- Given an iterator, iterate only over unique items
function it.unique(f, s, var)
	local set = {};

	return function ()
		while true do
			local ret = pack(f(s, var));
			var = ret[1];
			if var == nil then break; end
			if not set[var] then
				set[var] = true;
				return unpack(ret, 1, ret.n);
			end
		end
	end;
end

--[[ Return the number of items an iterator returns ]]--
function it.count(f, s, var)
	local x = 0;

	while true do
		var = f(s, var);
		if var == nil then break; end
		x = x + 1;
	end

	return x;
end

-- Return the first n items an iterator returns
function it.head(n, f, s, var)
	local c = 0;
	return function (_s, _var)
		if c >= n then
			return nil;
		end
		c = c + 1;
		return f(_s, _var);
	end, s, var;
end

-- Skip the first n items an iterator returns
function it.skip(n, f, s, var)
	for _ = 1, n do
		var = f(s, var);
	end
	return f, s, var;
end

-- Return the last n items an iterator returns
function it.tail(n, f, s, var)
	local results, count = {}, 0;
	while true do
		local ret = pack(f(s, var));
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
		local ret = results[((count-1+pos)%n)+1];
		return unpack(ret, 1, ret.n);
	end
	--return reverse(head(n, reverse(f, s, var))); -- !
end

function it.filter(filter, f, s, var)
	if type(filter) ~= "function" then
		local filter_value = filter;
		function filter(x) return x ~= filter_value; end
	end
	return function (_s, _var)
		local ret;
		repeat ret = pack(f(_s, _var));
			_var = ret[1];
		until _var == nil or filter(unpack(ret, 1, ret.n));
		return unpack(ret, 1, ret.n);
	end, s, var;
end

local function _ripairs_iter(t, key) if key > 1 then return key-1, t[key-1]; end end
function it.ripairs(t)
	return _ripairs_iter, t, #t+1;
end

local function _range_iter(max, curr) if curr < max then return curr + 1; end end
function it.range(x, y)
	if not y then x, y = 1, x; end -- Default to 1..x if y not given
	return _range_iter, y, x-1;
end

-- Convert the values returned by an iterator to an array
function it.to_array(f, s, var)
	local t = {};
	while true do
		var = f(s, var);
		if var == nil then break; end
		t_insert(t, var);
	end
	return t;
end

function it.sorted_pairs(t, sort_func)
	local keys = it.to_array(it.keys(t));
	table.sort(keys, sort_func);
	local i = 0;
	return function ()
		i = i + 1;
		local key = keys[i];
		if key ~= nil then
			return key, t[key];
		end
	end;
end

-- Treat the return of an iterator as key,value pairs,
-- and build a table
function it.to_table(f, s, var)
	local t, var2 = {};
	while true do
		var, var2 = f(s, var);
		if var == nil then break; end
		t[var] = var2;
	end
	return t;
end

local function _join_iter(j_s, j_var)
	local iterators, current_idx = j_s[1], j_s[2];
	local f, s, var = unpack(iterators[current_idx], 1, 3);
	if j_var ~= nil then
		var = j_var;
	end
	local ret = pack(f(s, var));
	local var1 = ret[1];
	if var1 == nil then
		-- End of this iterator, advance to next
		if current_idx == #iterators then
			-- No more iterators, return nil
			return;
		end
		j_s[2] = current_idx + 1;
		return _join_iter(j_s);
	end
	return unpack(ret, 1, ret.n);
end
local join_methods = {};
local join_mt = {
	__index = join_methods;
	__call = function (t, s, var) --luacheck: ignore 212/t
		return _join_iter(s, var);
	end;
};

function join_methods:append(f, s, var)
	table.insert(self, { f, s, var });
	return self, { self, 1 };
end

function join_methods:prepend(f, s, var)
	table.insert(self, { f, s, var }, 1);
	return self, { self, 1 };
end

function it.join(f, s, var)
	return setmetatable({ {f, s, var} }, join_mt);
end

return it;
