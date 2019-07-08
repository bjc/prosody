-- Prosody IM
-- Copyright (C) 2008-2015 Matthew Wild
-- Copyright (C) 2008-2015 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

-- Small ringbuffer library (i.e. an efficient FIFO queue with a size limit)
-- (because unbounded dynamically-growing queues are a bad thing...)

local have_utable, utable = pcall(require, "util.table"); -- For pre-allocation of table

local function new(size, allow_wrapping)
	-- Head is next insert, tail is next read
	local head, tail = 1, 1;
	local items = 0; -- Number of stored items
	local t = have_utable and utable.create(size, 0) or {}; -- Table to hold items
	--luacheck: ignore 212/self
	return {
		_items = t;
		size = size;
		count = function (self) return items; end;
		push = function (self, item)
			if items >= size then
				if allow_wrapping then
					tail = (tail%size)+1; -- Advance to next oldest item
					items = items - 1;
				else
					return nil, "queue full";
				end
			end
			t[head] = item;
			items = items + 1;
			head = (head%size)+1;
			return true;
		end;
		pop = function (self)
			if items == 0 then
				return nil;
			end
			local item;
			item, t[tail] = t[tail], 0;
			tail = (tail%size)+1;
			items = items - 1;
			return item;
		end;
		peek = function (self)
			if items == 0 then
				return nil;
			end
			return t[tail];
		end;
		items = function (self)
			return function (_, pos)
				if pos >= items then
					return nil;
				end
				local read_pos = tail + pos;
				if read_pos > self.size then
					read_pos = (read_pos%size);
				end
				return pos+1, t[read_pos];
			end, self, 0;
		end;
		consume = function (self)
			return self.pop, self;
		end;
	};
end

return {
	new = new;
};

