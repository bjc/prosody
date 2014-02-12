
local setmetatable = setmetatable;
local math_floor = math.floor;
local t_remove = table.remove;

local function _heap_insert(self, item, sync, item2, index)
	local pos = #self + 1;
	while true do
		local half_pos = math_floor(pos / 2);
		if half_pos == 0 or item > self[half_pos] then break; end
		self[pos] = self[half_pos];
		sync[pos] = sync[half_pos];
		index[sync[pos]] = pos;
		pos = half_pos;
	end
	self[pos] = item;
	sync[pos] = item2;
	index[item2] = pos;
end

local function _percolate_up(self, k, sync, index)
	local tmp = self[k];
	local tmp_sync = sync[k];
	while k ~= 1 do
		local parent = math_floor(k/2);
		if tmp < self[parent] then break; end
		self[k] = self[parent];
		sync[k] = sync[parent];
		index[sync[k]] = k;
		k = parent;
	end
	self[k] = tmp;
	sync[k] = tmp_sync;
	index[tmp_sync] = k;
	return k;
end

local function _percolate_down(self, k, sync, index)
	local tmp = self[k];
	local tmp_sync = sync[k];
	local size = #self;
	local child = 2*k;
	while 2*k <= size do
		if child ~= size and self[child] > self[child + 1] then
			child = child + 1;
		end
		if tmp > self[child] then
			self[k] = self[child];
			sync[k] = sync[child];
			index[sync[k]] = k;
		else
			break;
		end

		k = child;
		child = 2*k;
	end
	self[k] = tmp;
	sync[k] = tmp_sync;
	index[tmp_sync] = k;
	return k;
end

local function _heap_pop(self, sync, index)
	local size = #self;
	if size == 0 then return nil; end

	local result = self[1];
	local result_sync = sync[1];
	index[result_sync] = nil;
	if size == 1 then
		self[1] = nil;
		sync[1] = nil;
		return result, result_sync;
	end
	self[1] = t_remove(self);
	sync[1] = t_remove(sync);
	index[sync[1]] = 1;

	_percolate_down(self, 1, sync, index);

	return result, result_sync;
end

local indexed_heap = {};

function indexed_heap:insert(item, priority, id)
	if id == nil then
		id = self.current_id;
		self.current_id = id + 1;
	end
	self.items[id] = item;
	_heap_insert(self.priorities, priority, self.ids, id, self.index);
	return id;
end
function indexed_heap:pop()
	local priority, id = _heap_pop(self.priorities, self.ids, self.index);
	if id then
		local item = self.items[id];
		self.items[id] = nil;
		return priority, item, id;
	end
end
function indexed_heap:peek()
	return self.priorities[1];
end
function indexed_heap:reprioritize(id, priority)
	local k = self.index[id];
	if k == nil then return; end
	self.priorities[k] = priority;

	k = _percolate_up(self.priorities, k, self.ids, self.index);
	k = _percolate_down(self.priorities, k, self.ids, self.index);
end
function indexed_heap:remove_index(k)
	local size = #self.priorities;

	local result = self.priorities[k];
	local result_sync = self.ids[k];
	local item = self.items[result_sync];
	if result == nil then return; end
	self.index[result_sync] = nil;
	self.items[result_sync] = nil;

	self.priorities[k] = self.priorities[size];
	self.ids[k] = self.ids[size];
	self.index[self.ids[k]] = k;
	t_remove(self.priorities);
	t_remove(self.ids);

	k = _percolate_up(self.priorities, k, self.ids, self.index);
	k = _percolate_down(self.priorities, k, self.ids, self.index);

	return result, item, result_sync;
end
function indexed_heap:remove(id)
	return self:remove_index(self.index[id]);
end

local mt = { __index = indexed_heap };

local _M = {
	create = function()
		return setmetatable({
			ids = {}; -- heap of ids, sync'd with priorities
			items = {}; -- map id->items
			priorities = {}; -- heap of priorities
			index = {}; -- map of id->index of id in ids
			current_id = 1.5
		}, mt);
	end
};
return _M;
