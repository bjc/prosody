local ipairs, pairs = 
      ipairs, pairs;

module "set"

function new(list)
	local items = {};
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
		for _, item in ipairs(list) do
			items[item] = true;
		end
	end
	
	function set:include(otherset)
		for item in pairs(otherset) do
			items[item] = true;
		end
	end

	function set:exclude(otherset)
		for item in pairs(otherset) do
			items[item] = nil;
		end
	end
	
	if list then
		set:add_list(list);
	end
	
	return set;
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

return _M;
