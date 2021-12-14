local queue = require("util.queue");

local lib = { smqueue = {} }

local smqueue = lib.smqueue;

function smqueue:push(v)
	self._head = self._head + 1;

	assert(self._queue:push(v));
end

function smqueue:ack(h)
	if h < self._tail then
		return nil, "tail"
	elseif h > self._head then
		return nil, "head"
	end

	local acked = {};
	self._tail = h;
	local expect = self._head - self._tail;
	while expect < self._queue:count() do
		local v = self._queue:pop();
		if not v then return nil, "pop" end
		table.insert(acked, v);
	end
	return acked
end

function smqueue:count_unacked() return self._head - self._tail end

function smqueue:count_acked() return self._tail end

function smqueue:resumable() return self._queue:count() >= (self._head - self._tail) end

function smqueue:resume() return self._queue:items() end

function smqueue:consume() return self._queue:consume() end

local compat_mt = {}

function compat_mt:__index(i)
	if i < self._queue._tail then return nil end
	return self._queue._queue._items[(i + self._queue._tail) % self._queue._queue.size]
end

function compat_mt:__len() return self._queue:count_unacked() end

function smqueue:table() return setmetatable({ _queue = self }, compat_mt) end

local function freeze(q) return { head = q._head; tail = q._tail } end

local queue_mt = { __name = "smqueue"; __index = smqueue; __len = smqueue.count_unacked; __freeze = freeze }

function lib.new(size)
	assert(size > 0);
	return setmetatable({ _head = 0; _tail = 0; _queue = queue.new(size, true) }, queue_mt)
end

return lib
