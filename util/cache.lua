local cache_methods = {};
local cache_mt = { __index = cache_methods };

local function new(size)
	assert(size > 0, "cache size must be greater than zero");
	local data = {};
	return setmetatable({ data = data, count = 0, size = size, head = nil, tail = nil }, cache_mt);
end

local function _remove(list, m)
	if m.prev then
		m.prev.next = m.next;
	end
	if m.next then
		m.next.prev = m.prev;
	end
	if list.tail == m then
		list.tail = m.prev;
	end
	if list.head == m then
		list.head = m.next;
	end
	list.count = list.count - 1;
end

local function _insert(list, m)
	if list.head then
		list.head.prev = m;
	end
	m.prev, m.next = nil, list.head;
	list.head = m;
	if not list.tail then
		list.tail = m;
	end
	list.count = list.count + 1;
end

function cache_methods:set(k, v)
	local m = self.data[k];
	if m then
		-- Key already exists
		if v ~= nil then
			-- Bump to head of list
			_remove(self, m);
			_insert(self, m);
			m.value = v;
		else
			-- Remove from list
			_remove(self, m);
			self.data[k] = nil;
		end
		return;
	end
	-- New key
	if v == nil then
		return;
	end
	-- Check whether we need to remove oldest k/v
	if self.count == self.size then
		self.data[self.tail.key] = nil;
		_remove(self, self.tail);
	end

	m = { key = k, value = v, prev = nil, next = nil };
	self.data[k] = m;
	_insert(self, m);
end

function cache_methods:get(k)
	local m = self.data[k];
	if m then
		return m.value;
	end
	return nil;
end

function cache_methods:items()
	local m = self.head;
	return function ()
		if not m then
			return;
		end
		local k, v = m.key, m.value;
		m = m.next;
		return k, v;
	end
end

return {
	new = new;
}
