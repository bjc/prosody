-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local select = select;
local t_insert = table.insert;
local unpack, pairs, next, type = unpack, pairs, next, type;

module "multitable"

local function get(self, ...)
	local t = self.data;
	for n = 1,select('#', ...) do
		t = t[select(n, ...)];
		if not t then break; end
	end
	return t;
end

local function add(self, ...)
	local t = self.data;
	local count = select('#', ...);
	for n = 1,count-1 do
		local key = select(n, ...);
		local tab = t[key];
		if not tab then tab = {}; t[key] = tab; end
		t = tab;
	end
	t_insert(t, (select(count, ...)));
end

local function set(self, ...)
	local t = self.data;
	local count = select('#', ...);
	for n = 1,count-2 do
		local key = select(n, ...);
		local tab = t[key];
		if not tab then tab = {}; t[key] = tab; end
		t = tab;
	end
	t[(select(count-1, ...))] = (select(count, ...));
end

local function r(t, n, _end, ...)
	if t == nil then return; end
	local k = select(n, ...);
	if n == _end then
		t[k] = nil;
		return;
	end
	if k then
		local v = t[k];
		if v then
			r(v, n+1, _end, ...);
			if not next(v) then
				t[k] = nil;
			end
		end
	else
		for _,b in pairs(t) do
			r(b, n+1, _end, ...);
			if not next(b) then
				t[_] = nil;
			end
		end
	end
end

local function remove(self, ...)
	local _end = select('#', ...);
	for n = _end,1 do
		if select(n, ...) then _end = n; break; end
	end
	r(self.data, 1, _end, ...);
end


local function s(t, n, results, _end, ...)
	if t == nil then return; end
	local k = select(n, ...);
	if n == _end then
		if k == nil then
			for _, v in pairs(t) do
				t_insert(results, v);
			end
		else
			t_insert(results, t[k]);
		end
		return;
	end
	if k then
		local v = t[k];
		if v then
			s(v, n+1, results, _end, ...);
		end
	else
		for _,b in pairs(t) do
			s(b, n+1, results, _end, ...);
		end
	end
end

-- Search for keys, nil == wildcard
local function search(self, ...)
	local _end = select('#', ...);
	for n = _end,1 do
		if select(n, ...) then _end = n; break; end
	end
	local results = {};
	s(self.data, 1, results, _end, ...);
	return results;
end

-- Append results to an existing list
local function search_add(self, results, ...)
	if not results then results = {}; end
	local _end = select('#', ...);
	for n = _end,1 do
		if select(n, ...) then _end = n; break; end
	end
	s(self.data, 1, results, _end, ...);
	return results;
end

function iter(self, ...)
	local query = { ... };
	local maxdepth = select("#", ...);
	local stack = { self.data };
	local keys = { };
	local function it(self)
		local depth = #stack;
		local key = next(stack[depth], keys[depth]);
		if key == nil then -- Go up the stack
			stack[depth], keys[depth] = nil, nil;
			if depth > 1 then
				return it(self);
			end
			return; -- The end
		else
			keys[depth] = key;
		end
		local value = stack[depth][key];
		if query[depth] == nil or key == query[depth] then
			if depth == maxdepth then -- Result
				local result = {}; -- Collect keys forming path to result
				for i = 1, depth do
					result[i] = keys[i];
				end
				result[depth+1] = value;
				return unpack(result, 1, depth+1);
			elseif type(value) == "table" then
				t_insert(stack, value); -- Descend
			end
		end
		return it(self);
	end;
	return it, self;
end

function new()
	return {
		data = {};
		get = get;
		add = add;
		set = set;
		remove = remove;
		search = search;
		search_add = search_add;
		iter = iter;
	};
end

return _M;
