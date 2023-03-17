local queue = require "prosody.util.queue";

local s_byte, s_sub = string.byte, string.sub;
local dbuffer_methods = {};
local dynamic_buffer_mt = { __name = "dbuffer", __index = dbuffer_methods };

function dbuffer_methods:write(data)
	if self.max_size and #data + self._length > self.max_size then
		return nil;
	end
	local ok = self.items:push(data);
	if not ok then
		self:collapse();
		ok = self.items:push(data);
	end
	if not ok then
		return nil;
	end
	self._length = self._length + #data;
	return true;
end

function dbuffer_methods:read_chunk(requested_bytes)
	local chunk, consumed = self.items:peek(), self.front_consumed;
	if not chunk then return; end
	local chunk_length = #chunk;
	local remaining_chunk_length = chunk_length - consumed;
	if not requested_bytes then
		requested_bytes = remaining_chunk_length;
	end
	if remaining_chunk_length <= requested_bytes then
		self.front_consumed = 0;
		self._length = self._length - remaining_chunk_length;
		self.items:pop();
		assert(#chunk:sub(consumed + 1, -1) == remaining_chunk_length);
		return chunk:sub(consumed + 1, -1), remaining_chunk_length;
	end
	local end_pos = consumed + requested_bytes;
	self.front_consumed = end_pos;
	self._length = self._length - requested_bytes;
	assert(#chunk:sub(consumed + 1, end_pos) == requested_bytes);
	return chunk:sub(consumed + 1, end_pos), requested_bytes;
end

function dbuffer_methods:read(requested_bytes)
	local chunks;

	if requested_bytes and requested_bytes > self._length then
		return nil;
	end

	local chunk, read_bytes = self:read_chunk(requested_bytes);
	if not requested_bytes then
		return chunk;
	elseif chunk then
		requested_bytes = requested_bytes - read_bytes;
		if requested_bytes == 0 then -- Already read everything we need
			return chunk;
		end
		chunks = {};
	else
		return nil;
	end

	-- Need to keep reading more chunks
	while chunk do
		table.insert(chunks, chunk);
		if requested_bytes > 0 then
			chunk, read_bytes = self:read_chunk(requested_bytes);
			requested_bytes = requested_bytes - read_bytes;
		else
			break;
		end
	end

	return table.concat(chunks);
end

-- Read to, and including, the specified character sequence (return nil if not found)
function dbuffer_methods:read_until(char)
	local buffer_pos = 0;
	for i, chunk in self.items:items() do
		local start = 1 + ((i == 1) and self.front_consumed or 0);
		local char_pos = chunk:find(char, start, true);
		if char_pos then
			return self:read(1 + buffer_pos + char_pos - start);
		end
		buffer_pos = buffer_pos + #chunk - (start - 1);
	end
	return nil;
end

function dbuffer_methods:discard(requested_bytes)
	if self._length == 0 then return true; end
	if not requested_bytes or requested_bytes >= self._length then
		self.front_consumed = 0;
		self._length = 0;
		for _ in self.items:consume() do end
		return true;
	end

	local chunk, read_bytes = self:read_chunk(requested_bytes);
	requested_bytes = requested_bytes - read_bytes;
	if requested_bytes == 0 then -- Already read everything we need
		return true;
	end

	while chunk do
		if requested_bytes > 0 then
			chunk, read_bytes = self:read_chunk(requested_bytes);
			requested_bytes = requested_bytes - read_bytes;
		else
			break;
		end
	end
	return true;
end

-- Normalize i, j into absolute offsets within the
-- front chunk (accounting for front_consumed), and
-- ensure there is enough data in the first chunk
-- to cover any subsequent :sub() or :byte() operation
function dbuffer_methods:_prep_sub(i, j)
	if j == nil then
		j = -1;
	end
	if j < 0 then
		j = self._length + (j+1);
	end
	if i < 0 then
		i = self._length + (i+1);
	end
	if i < 1 then
		i = 1;
	end
	if j > self._length then
		j = self._length;
	end
	if i > j then
		return nil;
	end

	self:collapse(j);

	if self.front_consumed > 0 then
		i = i + self.front_consumed;
		j = j + self.front_consumed;
	end

	return i, j;
end

function dbuffer_methods:sub(i, j)
	i, j = self:_prep_sub(i, j);
	if not i then
		return "";
	end
	return s_sub(self.items:peek(), i, j);
end

function dbuffer_methods:byte(i, j)
	i = i or 1;
	j = j or i;
	i, j = self:_prep_sub(i, j);
	if not i then
		return;
	end
	return s_byte(self.items:peek(), i, j);
end

function dbuffer_methods:length()
	return self._length;
end
dbuffer_methods.len = dbuffer_methods.length; -- strings have :len()
dynamic_buffer_mt.__len = dbuffer_methods.length; -- support # operator

function dbuffer_methods:collapse(bytes)
	bytes = bytes or self._length;

	local front_chunk = self.items:peek();

	if not front_chunk or #front_chunk - self.front_consumed >= bytes then
		return;
	end

	local front_chunks = { front_chunk:sub(self.front_consumed+1) };
	local front_bytes = #front_chunks[1];

	while front_bytes < bytes do
		self.items:pop();
		local chunk = self.items:peek();
		front_bytes = front_bytes + #chunk;
		table.insert(front_chunks, chunk);
	end
	self.items:replace(table.concat(front_chunks));
	self.front_consumed = 0;
end

local function new(max_size, max_chunks)
	if max_size and max_size <= 0 then
		return nil;
	end
	return setmetatable({
		front_consumed = 0;
		_length = 0;
		max_size = max_size;
		items = queue.new(max_chunks or 32);
	}, dynamic_buffer_mt);
end

return {
	new = new;
};
