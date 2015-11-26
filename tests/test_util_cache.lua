
function new(new)
	local c = new(5);

	assert_equal(c:count(), 0);
	
	c:set("one", 1)
	assert_equal(c:count(), 1);
	c:set("two", 2)
	c:set("three", 3)
	c:set("four", 4)
	c:set("five", 5);
	assert_equal(c:count(), 5);
	
	c:set("foo", nil);
	assert_equal(c:count(), 5);
	
	assert_equal(c:get("one"), 1);
	assert_equal(c:get("two"), 2);
	assert_equal(c:get("three"), 3);
	assert_equal(c:get("four"), 4);
	assert_equal(c:get("five"), 5);

	assert_equal(c:get("foo"), nil);
	assert_equal(c:get("bar"), nil);
	
	c:set("six", 6);
	assert_equal(c:count(), 5);
	
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
	

end
