local queue = require "prosody.util.queue";

local record lib
	-- T would typically be util.stanza
	record smqueue<T>
		_queue : queue.queue<T>
		_head : integer
		_tail : integer

		enum ack_errors
			"tail"
			"head"
			"pop"
		end
		push : function (smqueue<T>, T)
		ack : function (smqueue<T>, integer) : { T }, ack_errors
		resumable : function (smqueue<T>) : boolean
		resume : function (smqueue<T>)  : queue.queue.iterator, any, integer
		consume : function (smqueue<T>) : function() : T

		table : function (smqueue<T>) : { T }
	end
	new : function <T>(integer) : smqueue<T>
end

local type smqueue = lib.smqueue;

function smqueue:push(v : T)
	self._head = self._head + 1;
	-- Wraps instead of errors
	assert(self._queue:push(v));
end

function smqueue:ack(h : integer) : { T }, smqueue.ack_errors
	if h < self._tail then
		return nil, "tail";
	elseif h > self._head then
		return nil, "head";
	end
	-- TODO optimize? cache table fields
	local acked = {};
	self._tail = h;
	local expect = self._head - self._tail;
	while expect < self._queue:count() do
		local v = self._queue:pop();
		if not v then return nil, "pop"; end
		table.insert(acked, v);
	end
	return acked;
end

function smqueue:count_unacked() : integer
	return self._head - self._tail;
end

function smqueue:count_acked() : integer
	return self._tail;
end

function smqueue:resumable() : boolean
	return self._queue:count() >= (self._head - self._tail);
end

function smqueue:resume() : queue.queue.iterator, any, integer
	return self._queue:items();
end

function smqueue:consume() : (function() : T)
	return self._queue:consume() as (function() : T)
end

-- Compatibility layer, plain ol' table
function smqueue:table() : { T }
	local t : { T } = {};
	for i, v in self:resume() do
		t[i] = v;
	end
	return t;
end

local function freeze(q : smqueue<any>) : { string:integer }
	return { head = q._head, tail = q._tail }
end

local queue_mt = {
	--
	__name = "smqueue";
	__index = smqueue;
	__len = smqueue.count_unacked;
	__freeze = freeze;
}

function lib.new<T>(size : integer) : smqueue<T>
	assert(size>0);
	return setmetatable({ _head = 0; _tail = 0; _queue = queue.new(size, true) }, queue_mt);
end

return lib;
