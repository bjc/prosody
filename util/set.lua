-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local ipairs, pairs, setmetatable, next, tostring =
      ipairs, pairs, setmetatable, next, tostring;
local t_concat = table.concat;

module "set"

local set_mt = {};
function set_mt.__call(set, _, k)
	return next(set._items, k);
end
function set_mt.__add(set1, set2)
	return _M.union(set1, set2);
end
function set_mt.__sub(set1, set2)
	return _M.difference(set1, set2);
end
function set_mt.__div(set, func)
	local new_set, new_items = _M.new();
	local items, new_items = set._items, new_set._items;
	for item in pairs(items) do
		local new_item = func(item);
		if new_item ~= nil then
			new_items[new_item] = true;
		end
	end
	return new_set;
end
function set_mt.__eq(set1, set2)
	local set1, set2 = set1._items, set2._items;
	for item in pairs(set1) do
		if not set2[item] then
			return false;
		end
	end
	
	for item in pairs(set2) do
		if not set1[item] then
			return false;
		end
	end
	
	return true;
end
function set_mt.__tostring(set)
	local s, items = { }, set._items;
	for item in pairs(items) do
		s[#s+1] = tostring(item);
	end
	return t_concat(s, ", ");
end

local items_mt = {};
function items_mt.__call(items, _, k)
	return next(items, k);
end

function new(list)
	local items = setmetatable({}, items_mt);
	local set = { _items = items };
	
	function set:add(item)
		items[item] = true;
	end
	
	function set:contains(item)
		return items[item];
	end
	
	function set:items()
		return items;
	end
	
	function set:remove(item)
		items[item] = nil;
	end
	
	function set:add_list(list)
		if list then
			for _, item in ipairs(list) do
				items[item] = true;
			end
		end
	end
	
	function set:include(otherset)
		for item in otherset do
			items[item] = true;
		end
	end

	function set:exclude(otherset)
		for item in otherset do
			items[item] = nil;
		end
	end
	
	function set:empty()
		return not next(items);
	end
	
	if list then
		set:add_list(list);
	end
	
	return setmetatable(set, set_mt);
end

function union(set1, set2)
	local set = new();
	local items = set._items;
	
	for item in pairs(set1._items) do
		items[item] = true;
	end

	for item in pairs(set2._items) do
		items[item] = true;
	end
	
	return set;
end

function difference(set1, set2)
	local set = new();
	local items = set._items;
	
	for item in pairs(set1._items) do
		items[item] = (not set2._items[item]) or nil;
	end

	return set;
end

function intersection(set1, set2)
	local set = new();
	local items = set._items;
	
	set1, set2 = set1._items, set2._items;
	
	for item in pairs(set1) do
		items[item] = (not not set2[item]) or nil;
	end
	
	return set;
end

function xor(set1, set2)
	return union(set1, set2) - intersection(set1, set2);
end

return _M;
