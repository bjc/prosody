
local now = 0; -- wibbly-wobbly... timey-wimey... stuff
local function predictable_gettime()
	return now;
end
local function later(n)
	now = now + n; -- time passes at a different rate
end

local function override_gettime(throttle)
	local i = 0;
	repeat
		i = i + 1;
		local name = debug.getupvalue(throttle.update, i);
		if name then
			debug.setupvalue(throttle.update, i, predictable_gettime);
			return throttle;
		end
	until not name;
end

function create(create)
	local a = override_gettime( create(3, 10) );

	assert_equal(a:poll(1), true);  -- 3 -> 2
	assert_equal(a:poll(1), true);  -- 2 -> 1
	assert_equal(a:poll(1), true);  -- 1 -> 0
	assert_equal(a:poll(1), false); -- MEEP, out of credits!
	later(1);                       -- ... what about
	assert_equal(a:poll(1), false); -- now? - Still no!
	later(9);                       -- Later that day
	assert_equal(a:poll(1), true);  -- Should be back at 3 credits ... 2
end

