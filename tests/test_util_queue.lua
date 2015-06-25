local new = require "util.queue".new;

local q = new(10);

assert(q.size == 10);
assert(q:count() == 0);

assert(q:push("one"));
assert(q:push("two"));
assert(q:push("three"));

for i = 4, 10 do
	print("pushing "..i)
	assert(q:push("hello"));
	assert(q:count() == i, "count is not "..i.."("..q:count()..")");
end
assert(q:push("hello") == nil, "queue overfull!");
assert(q:push("hello") == nil, "queue overfull!");
assert(q:pop() == "one", "queue item incorrect");
assert(q:pop() == "two", "queue item incorrect");
assert(q:push("hello"));
assert(q:push("hello"));
assert(q:pop() == "three", "queue item incorrect");
assert(q:push("hello"));
assert(q:push("hello") == nil, "queue overfull!");
assert(q:push("hello") == nil, "queue overfull!");

assert(q:count() == 10, "queue count incorrect");

for i = 1, 10 do
	assert(q:pop() == "hello", "queue item incorrect");
end

assert(q:count() == 0, "queue count incorrect");

assert(q:push(1));
for i = 1, 1001 do
	assert(q:pop() == i);
	assert(q:count() == 0);
	assert(q:push(i+1));
	assert(q:count() == 1);
end
assert(q:pop() == 1002);
assert(q:push(1));
for i = 1, 1000000 do
	q:pop();
	q:push(i+1);
end

-- Test queues that purge old items when pushing to a full queue
local q = new(10, true);

for i = 1, 10 do
	q:push(i);
end

assert(q:count() == 10);

assert(q:push(11));
assert(q:count() == 10);
assert(q:pop() == 2); -- First item should have been purged

for i = 12, 32 do
	assert(q:push(i));
end

assert(q:count() == 10);
assert(q:pop() == 23);
