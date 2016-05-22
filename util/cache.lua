
local function _remove(list, m)
	if m.prev then
		m.prev.next = m.next;
	end
	if m.next then
		m.next.prev = m.prev;
	end
	if list._tail == m then
		list._tail = m.prev;
	end
	if list._head == m then
		list._head = m.next;
	end
	list._count = list._count - 1;
end

local function _insert(list, m)
	if list._head then
		list._head.prev = m;
	end
	m.prev, m.next = nil, list._head;
	list._head = m;
	if not list._tail then
		list._tail = m;
	end
	list._count = list._count + 1;
end

local cache_methods = {};
local cache_mt = { __index = cache_methods };

function cache_methods:set(k, v)
	local m = self._data[k];
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
			self._data[k] = nil;
		end
		return true;
	end
	-- New key
	if v == nil then
		return true;
	end
	-- Check whether we need to remove oldest k/v
	if self._count == self.size then
		local tail = self._tail;
		local on_evict, evicted_key, evicted_value = self._on_evict, tail.key, tail.value;
		if on_evict ~= nil and (on_evict == false or on_evict(evicted_key, evicted_value) == false) then
			-- Cache is full, and we're not allowed to evict
			return false;
		end
		_remove(self, tail);
		self._data[evicted_key] = nil;
	end

	m = { key = k, value = v, prev = nil, next = nil };
	self._data[k] = m;
	_insert(self, m);
	return true;
end

function cache_methods:get(k)
	local m = self._data[k];
	if m then
		return m.value;
	end
	return nil;
end

function cache_methods:items()
	local m = self._head;
	return function ()
		if not m then
			return;
		end
		local k, v = m.key, m.value;
		m = m.next;
		return k, v;
	end
end

function cache_methods:values()
	local m = self._head;
	return function ()
		if not m then
			return;
		end
		local v = m.value;
		m = m.next;
		return v;
	end
end

function cache_methods:count()
	return self._count;
end

function cache_methods:head()
	local head = self._head;
	if not head then return nil, nil; end
	return head.key, head.value;
end

function cache_methods:tail()
	local tail = self._tail;
	if not tail then return nil, nil; end
	return tail.key, tail.value;
end

function cache_methods:table()
	if not self.proxy_table then
		self.proxy_table = setmetatable({}, {
			__index = function (t, k)
				return self:get(k);
			end;
			__newindex = function (t, k, v)
				if not self:set(k, v) then
					error("failed to insert key into cache - full");
				end
			end;
			__pairs = function (t)
				return self:items();
			end;
			__len = function (t)
				return self:count();
			end;
		});
	end
	return self.proxy_table;
end

local function new(size, on_evict)
	size = assert(tonumber(size), "cache size must be a number");
	size = math.floor(size);
	assert(size > 0, "cache size must be greater than zero");
	local data = {};
	return setmetatable({ _data = data, _count = 0, size = size, _head = nil, _tail = nil, _on_evict = on_evict }, cache_mt);
end

return {
	new = new;
}
