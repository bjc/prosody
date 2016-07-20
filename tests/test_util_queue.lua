
function new(new)
	do
		local q = new(10);

		assert_equal(q.size, 10);
		assert_equal(q:count(), 0);

		assert_is(q:push("one"));
		assert_is(q:push("two"));
		assert_is(q:push("three"));

		for i = 4, 10 do
			assert_is(q:push("hello"));
			assert_equal(q:count(), i, "count is not "..i.."("..q:count()..")");
		end
		assert_equal(q:push("hello"), nil, "queue overfull!");
		assert_equal(q:push("hello"), nil, "queue overfull!");
		assert_equal(q:pop(), "one", "queue item incorrect");
		assert_equal(q:pop(), "two", "queue item incorrect");
		assert_is(q:push("hello"));
		assert_is(q:push("hello"));
		assert_equal(q:pop(), "three", "queue item incorrect");
		assert_is(q:push("hello"));
		assert_equal(q:push("hello"), nil, "queue overfull!");
		assert_equal(q:push("hello"), nil, "queue overfull!");

		assert_equal(q:count(), 10, "queue count incorrect");

		for _ = 1, 10 do
			assert_equal(q:pop(), "hello", "queue item incorrect");
		end

		assert_equal(q:count(), 0, "queue count incorrect");

		assert_is(q:push(1));
		for i = 1, 1001 do
			assert_equal(q:pop(), i);
			assert_equal(q:count(), 0);
			assert_is(q:push(i+1));
			assert_equal(q:count(), 1);
		end
		assert_equal(q:pop(), 1002);
		assert_is(q:push(1));
		for i = 1, 1000000 do
			q:pop();
			q:push(i+1);
		end
	end

	do
		-- Test queues that purge old items when pushing to a full queue
		local q = new(10, true);

		for i = 1, 10 do
			q:push(i);
		end

		assert_equal(q:count(), 10);

		assert_is(q:push(11));
		assert_equal(q:count(), 10);
		assert_equal(q:pop(), 2); -- First item should have been purged

		for i = 12, 32 do
			assert_is(q:push(i));
		end

		assert_equal(q:count(), 10);
		assert_equal(q:pop(), 23);
	end
end
