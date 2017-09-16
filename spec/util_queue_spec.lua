
local queue = require "util.queue";

describe("util.queue", function()
	describe("#new()", function()
		it("should work", function()

			do
				local q = queue.new(10);

				assert.are.equal(q.size, 10);
				assert.are.equal(q:count(), 0);

				assert.is_true(q:push("one"));
				assert.is_true(q:push("two"));
				assert.is_true(q:push("three"));

				for i = 4, 10 do
					assert.is_true(q:push("hello"));
					assert.are.equal(q:count(), i, "count is not "..i.."("..q:count()..")");
				end
				assert.are.equal(q:push("hello"), nil, "queue overfull!");
				assert.are.equal(q:push("hello"), nil, "queue overfull!");
				assert.are.equal(q:pop(), "one", "queue item incorrect");
				assert.are.equal(q:pop(), "two", "queue item incorrect");
				assert.is_true(q:push("hello"));
				assert.is_true(q:push("hello"));
				assert.are.equal(q:pop(), "three", "queue item incorrect");
				assert.is_true(q:push("hello"));
				assert.are.equal(q:push("hello"), nil, "queue overfull!");
				assert.are.equal(q:push("hello"), nil, "queue overfull!");

				assert.are.equal(q:count(), 10, "queue count incorrect");

				for _ = 1, 10 do
					assert.are.equal(q:pop(), "hello", "queue item incorrect");
				end

				assert.are.equal(q:count(), 0, "queue count incorrect");
				assert.are.equal(q:pop(), nil, "empty queue pops non-nil result");
				assert.are.equal(q:count(), 0, "popping empty queue affects count");

				assert.are.equal(q:peek(), nil, "empty queue peeks non-nil result");
				assert.are.equal(q:count(), 0, "peeking empty queue affects count");

				assert.is_true(q:push(1));
				for i = 1, 1001 do
					assert.are.equal(q:pop(), i);
					assert.are.equal(q:count(), 0);
					assert.is_true(q:push(i+1));
					assert.are.equal(q:count(), 1);
				end
				assert.are.equal(q:pop(), 1002);
				assert.is_true(q:push(1));
				for i = 1, 1000 do
					assert.are.equal(q:pop(), i);
					assert.is_true(q:push(i+1));
				end
				assert.are.equal(q:pop(), 1001);
				assert.are.equal(q:count(), 0);
			end

			do
				-- Test queues that purge old items when pushing to a full queue
				local q = queue.new(10, true);

				for i = 1, 10 do
					q:push(i);
				end

				assert.are.equal(q:count(), 10);

				assert.is_true(q:push(11));
				assert.are.equal(q:count(), 10);
				assert.are.equal(q:pop(), 2); -- First item should have been purged
				assert.are.equal(q:peek(), 3);

				for i = 12, 32 do
					assert.is_true(q:push(i));
				end

				assert.are.equal(q:count(), 10);
				assert.are.equal(q:pop(), 23);
			end

			do
				-- Test iterator
				local q = queue.new(10, true);

				for i = 1, 10 do
					q:push(i);
				end

				local i = 0;
				for item in q:items() do
					i = i + 1;
					assert.are.equal(item, i, "unexpected item returned by iterator")
				end
			end

		end);
	end);
end);
