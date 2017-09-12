
-- Test passing nil to runner
-- Test runners work correctly after errors (coroutine gets recreated)
-- What happens if an error is thrown, but more items are in the queue? (I think runner might stall)
-- Test errors thrown halfway through a queue
-- Multiple runners

function runner(new_runner, async)
	local function new(func, name)
		local log = {};
		return new_runner(func, setmetatable({}, {
			__index = function (_, event)
				return function (runner, err)
					print(name, "event", event, err)
					table.insert(log, { event = event, err = err });
				end;
			end;
		})), log;
	end
	
	--------------------
	local r, l = new(function (item) assert(type(item) == "number") end);
	r:run(1);
	r:run(2);
	--for k, v in ipairs(l) do print(k,v) end

	--------------------
	local wait, done;

	local r, l = new(function (item)
		assert(type(item) == "number")
		if item == 3 then
			wait, done = async.waiter();
			wait();
		end
	end);
	
	r:run(1);
	assert(r.state == "ready");
	r:run(2);
	assert(r.state == "ready");
	r:run(3);
	assert(r.state == "waiting");
	done();
	assert(r.state == "ready");
	--for k, v in ipairs(l) do print(k,v) end

	--------------------
	local wait, done;
	local last_item = 0;
	local r, l = new(function (item)
		assert(type(item) == "number")
		assert(item == last_item + 1);
		last_item = item;
		if item == 3 then
			wait, done = async.waiter();
			wait();
		end
	end);
	
	r:run(1);
	assert(r.state == "ready");
	r:run(2);
	assert(r.state == "ready");
	r:run(3);
	assert(r.state == "waiting");
	r:run(4);
	assert(r.state == "waiting");
	done();
	assert(r.state == "ready");
	--for k, v in ipairs(l) do print(k,v) end

	--------------------
	local wait, done;
	local last_item = 0;
	local r, l = new(function (item)
		assert(type(item) == "number")
		assert((item == last_item + 1) or item == 3);
		last_item = item;
		if item == 3 then
			wait, done = async.waiter();
			wait();
		end
	end);
	
	r:run(1);
	assert(r.state == "ready");
	r:run(2);
	assert(r.state == "ready");
	
	local dones = {};
	r:run(3);
	assert(r.state == "waiting");
	r:run(3);
	assert(r.state == "waiting");
	r:run(3);
	assert(r.state == "waiting");
	r:run(4);
	assert(r.state == "waiting");

	for i = 1, 3 do
		done();
		if i < 3 then
			assert(r.state == "waiting");
		end
	end

	assert(r.state == "ready");
	--for k, v in ipairs(l) do print(k,v) end

	--------------------
	local wait, done;
	local last_item = 0;
	local r, l = new(function (item)
		assert(type(item) == "number")
		assert((item == last_item + 1) or item == 3);
		last_item = item;
		if item == 3 then
			wait, done = async.waiter();
			wait();
		end
	end);
	
	r:run(1);
	assert(r.state == "ready");
	r:run(2);
	assert(r.state == "ready");
	
	local dones = {};
	r:run(3);
	assert(r.state == "waiting");
	r:run(3);
	assert(r.state == "waiting");

	for i = 1, 2 do
		done();
		if i < 2 then
			assert(r.state == "waiting");
		end
	end

	assert(r.state == "ready");
	r:run(4);
	assert(r.state == "ready");

	assert(r.state == "ready");
	--for k, v in ipairs(l) do print(k,v) end

	-- Now with multiple runners
	--------------------
	local wait1, done1;
	local last_item1 = 0;
	local r1, l1 = new(function (item)
		assert(type(item) == "number")
		assert((item == last_item1 + 1) or item == 3);
		last_item1 = item;
		if item == 3 then
			wait1, done1 = async.waiter();
			wait1();
		end
	end, "r1");

	local wait2, done2;
	local last_item2 = 0;
	local r2, l2 = new(function (item)
		assert(type(item) == "number")
		assert((item == last_item2 + 1) or item == 3);
		last_item2 = item;
		if item == 3 then
			wait2, done2 = async.waiter();
			wait2();
		end
	end, "r2");
	
	r1:run(1);
	assert(r1.state == "ready");
	r1:run(2);
	assert(r1.state == "ready");
	
	local dones = {};
	r1:run(3);
	assert(r1.state == "waiting");
	r1:run(3);
	assert(r1.state == "waiting");

	r2:run(1);
	assert(r1.state == "waiting");
	assert(r2.state == "ready");

	r2:run(2);
	assert(r1.state == "waiting");
	assert(r2.state == "ready");

	r2:run(3);
	assert(r1.state == "waiting");
	assert(r2.state == "waiting");
	done2();

	r2:run(3);
	assert(r1.state == "waiting");
	assert(r2.state == "waiting");
	done2();

	r2:run(2);
	assert(r1.state == "waiting");
	assert(r2.state == "ready");

	for i = 1, 2 do
		done1();
		if i < 2 then
			assert(r1.state == "waiting");
		end
	end

	assert(r1.state == "ready");
	r1:run(4);
	assert(r1.state == "ready");

	assert(r1.state == "ready");
	--for k, v in ipairs(l1) do print(k,v) end
	

	--------------------
	local wait1, done1;
	local last_item1 = 0;
	local r1, l1 = new(function (item)
		assert(type(item) == "number")
		assert((item == last_item1 + 1) or item == 3);
		last_item1 = item;
		if item == 3 then
			wait1, done1 = async.waiter();
			wait1();
		end
	end, "r1");

	local wait2, done2;
	local last_item2 = 0;
	local r2, l2 = new(function (item)
		assert(type(item) == "number")
		assert((item == last_item2 + 1) or item == 3);
		last_item2 = item;
		if item == 3 then
			wait2, done2 = async.waiter();
			wait2();
		end
	end, "r2");
	
	r1:run(1);
	assert(r1.state == "ready");
	r1:run(2);
	assert(r1.state == "ready");
	
	r1:run(5);
	assert(r1.state == "ready");

	local dones = {};
	r1:run(3);
	assert(r1.state == "waiting");
	r1:run(5); -- Will error, when we get to it
	assert(r1.state == "waiting");
	r1:run(3);
	assert(r1.state == "waiting");

	r2:run(1);
	assert(r1.state == "waiting");
	assert(r2.state == "ready");

	r2:run(2);
	assert(r1.state == "waiting");
	assert(r2.state == "ready");

	r2:run(3);
	assert(r1.state == "waiting");
	assert(r2.state == "waiting");
	done2();

	r2:run(3);
	assert(r1.state == "waiting");
	assert(r2.state == "waiting");
	done2();

	r2:run(2);
	assert(r1.state == "waiting");
	assert(r2.state == "ready");

	for i = 1, 2 do
		done1();
		if i < 2 then
			assert_equal(r1.state, "waiting");
		end
	end

	assert(r1.state == "ready");
	r1:run(4);
	assert(r1.state == "ready");

	assert(r1.state == "ready");
	--for k, v in ipairs(l1) do print(k,v) end
	
	
end
