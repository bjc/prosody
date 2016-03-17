function new(new)
	local c = new(5);

	local function expect_kv(key, value, actual_key, actual_value)
		assert_equal(key, actual_key, "key incorrect");
		assert_equal(value, actual_value, "value incorrect");
	end

	expect_kv(nil, nil, c:head());
	expect_kv(nil, nil, c:tail());

	assert_equal(c:count(), 0);
	
	c:set("one", 1)
	assert_equal(c:count(), 1);
	expect_kv("one", 1, c:head());
	expect_kv("one", 1, c:tail());

	c:set("two", 2)
	expect_kv("two", 2, c:head());
	expect_kv("one", 1, c:tail());

	c:set("three", 3)
	expect_kv("three", 3, c:head());
	expect_kv("one", 1, c:tail());

	c:set("four", 4)
	c:set("five", 5);
	assert_equal(c:count(), 5);
	expect_kv("five", 5, c:head());
	expect_kv("one", 1, c:tail());
	
	c:set("foo", nil);
	assert_equal(c:count(), 5);
	expect_kv("five", 5, c:head());
	expect_kv("one", 1, c:tail());
	
	assert_equal(c:get("one"), 1);
	expect_kv("five", 5, c:head());
	expect_kv("one", 1, c:tail());

	assert_equal(c:get("two"), 2);
	assert_equal(c:get("three"), 3);
	assert_equal(c:get("four"), 4);
	assert_equal(c:get("five"), 5);

	assert_equal(c:get("foo"), nil);
	assert_equal(c:get("bar"), nil);
	
	c:set("six", 6);
	assert_equal(c:count(), 5);
	expect_kv("six", 6, c:head());
	expect_kv("two", 2, c:tail());
	
	assert_equal(c:get("one"), nil);
	assert_equal(c:get("two"), 2);
	assert_equal(c:get("three"), 3);
	assert_equal(c:get("four"), 4);
	assert_equal(c:get("five"), 5);
	assert_equal(c:get("six"), 6);
	
	c:set("three", nil);
	assert_equal(c:count(), 4);
	
	assert_equal(c:get("one"), nil);
	assert_equal(c:get("two"), 2);
	assert_equal(c:get("three"), nil);
	assert_equal(c:get("four"), 4);
	assert_equal(c:get("five"), 5);
	assert_equal(c:get("six"), 6);
	
	c:set("seven", 7);
	assert_equal(c:count(), 5);
	
	assert_equal(c:get("one"), nil);
	assert_equal(c:get("two"), 2);
	assert_equal(c:get("three"), nil);
	assert_equal(c:get("four"), 4);
	assert_equal(c:get("five"), 5);
	assert_equal(c:get("six"), 6);
	assert_equal(c:get("seven"), 7);
	
	c:set("eight", 8);
	assert_equal(c:count(), 5);
	
	assert_equal(c:get("one"), nil);
	assert_equal(c:get("two"), nil);
	assert_equal(c:get("three"), nil);
	assert_equal(c:get("four"), 4);
	assert_equal(c:get("five"), 5);
	assert_equal(c:get("six"), 6);
	assert_equal(c:get("seven"), 7);
	assert_equal(c:get("eight"), 8);
	
	c:set("four", 4);
	assert_equal(c:count(), 5);
	
	assert_equal(c:get("one"), nil);
	assert_equal(c:get("two"), nil);
	assert_equal(c:get("three"), nil);
	assert_equal(c:get("four"), 4);
	assert_equal(c:get("five"), 5);
	assert_equal(c:get("six"), 6);
	assert_equal(c:get("seven"), 7);
	assert_equal(c:get("eight"), 8);
	
	c:set("nine", 9);
	assert_equal(c:count(), 5);
	
	assert_equal(c:get("one"), nil);
	assert_equal(c:get("two"), nil);
	assert_equal(c:get("three"), nil);
	assert_equal(c:get("four"), 4);
	assert_equal(c:get("five"), nil);
	assert_equal(c:get("six"), 6);
	assert_equal(c:get("seven"), 7);
	assert_equal(c:get("eight"), 8);
	assert_equal(c:get("nine"), 9);

	local keys = { "nine", "four", "eight", "seven", "six" };
	local values = { 9, 4, 8, 7, 6 };
	local i = 0;	
	for k, v in c:items() do
		i = i + 1;
		assert_equal(k, keys[i]);
		assert_equal(v, values[i]);
	end
	assert_equal(i, 5);
	
	c:set("four", "2+2");
	assert_equal(c:count(), 5);

	assert_equal(c:get("one"), nil);
	assert_equal(c:get("two"), nil);
	assert_equal(c:get("three"), nil);
	assert_equal(c:get("four"), "2+2");
	assert_equal(c:get("five"), nil);
	assert_equal(c:get("six"), 6);
	assert_equal(c:get("seven"), 7);
	assert_equal(c:get("eight"), 8);
	assert_equal(c:get("nine"), 9);

	local keys = { "four", "nine", "eight", "seven", "six" };
	local values = { "2+2", 9, 8, 7, 6 };
	local i = 0;	
	for k, v in c:items() do
		i = i + 1;
		assert_equal(k, keys[i]);
		assert_equal(v, values[i]);
	end
	assert_equal(i, 5);
	
	c:set("foo", nil);
	assert_equal(c:count(), 5);

	assert_equal(c:get("one"), nil);
	assert_equal(c:get("two"), nil);
	assert_equal(c:get("three"), nil);
	assert_equal(c:get("four"), "2+2");
	assert_equal(c:get("five"), nil);
	assert_equal(c:get("six"), 6);
	assert_equal(c:get("seven"), 7);
	assert_equal(c:get("eight"), 8);
	assert_equal(c:get("nine"), 9);

	local keys = { "four", "nine", "eight", "seven", "six" };
	local values = { "2+2", 9, 8, 7, 6 };
	local i = 0;	
	for k, v in c:items() do
		i = i + 1;
		assert_equal(k, keys[i]);
		assert_equal(v, values[i]);
	end
	assert_equal(i, 5);
	
	c:set("four", nil);
	
	assert_equal(c:get("one"), nil);
	assert_equal(c:get("two"), nil);
	assert_equal(c:get("three"), nil);
	assert_equal(c:get("four"), nil);
	assert_equal(c:get("five"), nil);
	assert_equal(c:get("six"), 6);
	assert_equal(c:get("seven"), 7);
	assert_equal(c:get("eight"), 8);
	assert_equal(c:get("nine"), 9);

	local keys = { "nine", "eight", "seven", "six" };
	local values = { 9, 8, 7, 6 };
	local i = 0;	
	for k, v in c:items() do
		i = i + 1;
		assert_equal(k, keys[i]);
		assert_equal(v, values[i]);
	end
	assert_equal(i, 4);
	
	local evicted_key, evicted_value;
	local c = new(3, function (_key, _value)
		evicted_key, evicted_value = _key, _value;
	end);
	local function set(k, v, should_evict_key, should_evict_value)
		evicted_key, evicted_value = nil, nil;
		c:set(k, v);
		assert_equal(evicted_key, should_evict_key);
		assert_equal(evicted_value, should_evict_value);
	end
	set("a", 1)
	set("a", 1)
	set("a", 1)
	set("a", 1)
	set("a", 1)

	set("b", 2)
	set("c", 3)
	set("b", 2)
	set("d", 4, "a", 1)
	set("e", 5, "c", 3)
	

	local evicted_key, evicted_value;
	local c3 = new(1, function (_key, _value, c3)
		evicted_key, evicted_value = _key, _value;
		if _key == "a" then
			-- Put it back in...
			-- Check that the newest key/value was set before on_evict was called
			assert_equal(c3:get("b"), 2);
			-- Sanity check for what we're evicting
			assert_equal(_key, "a");
			assert_equal(_value, 1);
			-- Re-insert the evicted key (causes this evict function to run again with "b",2)
			c3:set(_key, _value)
			assert_equal(c3:get(_key), _value)
		end
	end);
	local function set(k, v, should_evict_key, should_evict_value)
		evicted_key, evicted_value = nil, nil;
		c3:set(k, v);
		assert_equal(evicted_key, should_evict_key);
		assert_equal(evicted_value, should_evict_value);
	end
	set("a", 1)
	set("a", 1)
	set("a", 1)
	set("a", 1)
	set("a", 1)

	-- The evict handler re-inserts "a"->1, so "b" gets evicted:
	set("b", 2, "b", 2)
	-- Check the final state is what we expect
	assert_equal(c3:get("a"), 1);
	assert_equal(c3:get("b"), nil);
	assert_equal(c3:count(), 1);
end
