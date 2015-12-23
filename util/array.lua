-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local t_insert, t_sort, t_remove, t_concat
    = table.insert, table.sort, table.remove, table.concat;

local setmetatable = setmetatable;
local math_random = math.random;
local math_floor = math.floor;
local pairs, ipairs = pairs, ipairs;
local tostring = tostring;
local type = type;

local array = {};
local array_base = {};
local array_methods = {};
local array_mt = { __index = array_methods, __tostring = function (array) return "{"..array:concat(", ").."}"; end };

local function new_array(self, t, _s, _var)
	if type(t) == "function" then -- Assume iterator
		t = self.collect(t, _s, _var);
	end
	return setmetatable(t or {}, array_mt);
end

function array_mt.__add(a1, a2)
	local res = new_array();
	return res:append(a1):append(a2);
end

setmetatable(array, { __call = new_array });

-- Read-only methods
function array_methods:random()
	return self[math_random(1, #self)];
end

-- These methods can be called two ways:
--   array.method(existing_array, [params [, ...]]) -- Create new array for result
--   existing_array:method([params, ...]) -- Transform existing array into result
--
function array_base.map(outa, ina, func)
	for k, v in ipairs(ina) do
		outa[k] = func(v);
	end
	return outa;
end

function array_base.filter(outa, ina, func)
	local inplace, start_length = ina == outa, #ina;
	local write = 1;
	for read = 1, start_length do
		local v = ina[read];
		if func(v) then
			outa[write] = v;
			write = write + 1;
		end
	end

	if inplace and write <= start_length then
		for i = write, start_length do
			outa[i] = nil;
		end
	end

	return outa;
end

function array_base.sort(outa, ina, ...)
	if ina ~= outa then
		outa:append(ina);
	end
	t_sort(outa, ...);
	return outa;
end

function array_base.pluck(outa, ina, key)
	for i = 1, #ina do
		outa[i] = ina[i][key];
	end
	return outa;
end

function array_base.reverse(outa, ina)
	local len = #ina;
	if ina == outa then
		local middle = math_floor(len/2);
		len = len + 1;
		local o; -- opposite
		for i = 1, middle do
			o = len - i;
			outa[i], outa[o] = outa[o], outa[i];
		end
	else
		local off = len + 1;
		for i = 1, len do
			outa[i] = ina[off - i];
		end
	end
	return outa;
end

--- These methods only mutate the array
function array_methods:shuffle(outa, ina)
	local len = #self;
	for i = 1, #self do
		local r = math_random(i, len);
		self[i], self[r] = self[r], self[i];
	end
	return self;
end

function array_methods:append(array)
	local len, len2 = #self, #array;
	for i = 1, len2 do
		self[len+i] = array[i];
	end
	return self;
end

function array_methods:push(x)
	t_insert(self, x);
	return self;
end

function array_methods:pop(x)
	local v = self[x];
	t_remove(self, x);
	return v;
end

function array_methods:concat(sep)
	return t_concat(array.map(self, tostring), sep);
end

function array_methods:length()
	return #self;
end

--- These methods always create a new array
function array.collect(f, s, var)
	local t = {};
	while true do
		var = f(s, var);
		if var == nil then break; end
		t_insert(t, var);
	end
	return setmetatable(t, array_mt);
end

---

-- Setup methods from array_base
for method, f in pairs(array_base) do
	local base_method = f;
	-- Setup global array method which makes new array
	array[method] = function (old_a, ...)
		local a = new_array();
		return base_method(a, old_a, ...);
	end
	-- Setup per-array (mutating) method
	array_methods[method] = function (self, ...)
		return base_method(self, self, ...);
	end
end

return array;
