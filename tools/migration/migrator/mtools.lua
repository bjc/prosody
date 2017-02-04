

local print = print;
local t_insert = table.insert;
local t_sort = table.sort;


local function sorted(params)

	local reader = params.reader; -- iterator to get items from
	local sorter = params.sorter; -- sorting function
	local filter = params.filter; -- filter function

	local cache = {};
	for item in reader do
		if filter then item = filter(item); end
		if item then t_insert(cache, item); end
	end
	if sorter then
		t_sort(cache, sorter);
	end
	local i = 0;
	return function()
		i = i + 1;
		return cache[i];
	end;

end

local function merged(reader, merger)

	local item1 = reader();
	local merged = { item1 };
	return function()
		while true do
			if not item1 then return nil; end
			local item2 = reader();
			if not item2 then item1 = nil; return merged; end
			if merger(item1, item2) then
			--print("merged")
				item1 = item2;
				t_insert(merged, item1);
			else
			--print("unmerged", merged)
				item1 = item2;
				local tmp = merged;
				merged = { item1 };
				return tmp;
			end
		end
	end;

end

return {
	sorted = sorted;
	merged = merged;
}
