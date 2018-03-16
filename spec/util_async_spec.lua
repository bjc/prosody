local async = require "util.async";

describe("util.async", function()
	local debug = false;
	local print = print;
	if debug then
		require "util.logger".add_simple_sink(print);
	else
		print = function () end
	end
	local function new(func, name)
		local log = {};
		return async.runner(func, setmetatable({}, {
			__index = function (_, event)
				return function (runner, err)
					print(name, "event", event, err)
					print "--"
					table.insert(log, { event = event, err = err });
				end;
			end;
		})), log;
	end
	describe("#runner", function()
		it("should work", function()			
			local r, l = new(function (item) assert(type(item) == "number") end);
			r:run(1);
			r:run(2);
		end);

		it("should be ready after creation", function ()
			local r = async.runner(function (item) end);
			assert.equal(r.state, "ready");
		end);

		describe("#errors", function ()
			local last_processed_item, last_error;
			local r;
			r = async.runner(function (item)
				if item == "error" then
					error({ e = "test error" });
				end
				last_processed_item = item;
			end, {
				error = function (runner, err)
					assert.equal(r, runner);
					last_error = err;
				end;
			});

			randomize(false);

			it("should notify", function ()
				local last_processed_item, last_error;
				local r;
				r = async.runner(function (item)
					if item == "error" then
						error({ e = "test error" });
					end
					last_processed_item = item;
				end, {
					error = function (runner, err)
						assert.equal(r, runner);
						last_error = err;
					end;
				});

				r:run("hello");
				assert.equal(r.state, "ready");
				assert.equal(last_processed_item, "hello");

				assert.equal(last_error, nil);
				r:run("error");
				assert.is_table(last_error);
				assert.equal(last_error.e, "test error");
				last_error = nil;
				assert.equal(r.state, "ready");
				assert.equal(last_processed_item, "hello");
			end);
			it("should not be fatal to the runner", function ()
				r:run("world");
				assert.equal(r.state, "ready");
				assert.equal(last_processed_item, "world");
			end);
		end);
	end);
	describe("#waiter", function()
		it("should error outside of async context", function ()
			assert.has_error(function ()
				async.waiter();
			end);
		end);
		it("should work", function ()
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
		end);
		
		it("should work", function ()
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
		end);
		it("should work", function ()
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
		end);
		it("should work", function ()
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
		end);
		it("should work with multiple runners in parallel", function ()
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
		
			r2:run(4);
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
		end);
		it("should work work with multiple runners in parallel", function ()
			--------------------
			local wait1, done1;
			local last_item1 = 0;
			local r1, l1 = new(function (item)
				print("r1 processing ", item);
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
				print("r2 processing ", item);
				assert.is_number(item);
				assert((item == last_item2 + 1) or item == 3);
				last_item2 = item;
				if item == 3 then
					wait2, done2 = async.waiter();
					wait2();
				end
			end, "r2");

			r1:run(1);
			assert.equal(r1.state, "ready");
			r1:run(2);
			assert.equal(r1.state, "ready");

			r1:run(5);
			assert.equal(r1.state, "ready");

			local dones = {};
			r1:run(3);
			assert.equal(r1.state, "waiting");
			r1:run(5); -- Will error, when we get to it
			assert.equal(r1.state, "waiting");
			done1();
			assert.equal(r1.state, "ready");
			r1:run(3);
			assert.equal(r1.state, "waiting");

			r2:run(1);
			assert.equal(r1.state, "waiting");
			assert.equal(r2.state, "ready");

			r2:run(2);
			assert.equal(r1.state, "waiting");
			assert.equal(r2.state, "ready");

			r2:run(3);
			assert.equal(r1.state, "waiting");
			assert.equal(r2.state, "waiting");

			done2();
			assert.equal(r1.state, "waiting");
			assert.equal(r2.state, "ready");

			r2:run(3);
			assert.equal(r1.state, "waiting");
			assert.equal(r2.state, "waiting");

			done2();
			assert.equal(r1.state, "waiting");
			assert.equal(r2.state, "ready");

			r2:run(4);
			assert.equal(r1.state, "waiting");
			assert.equal(r2.state, "ready");

			done1();
		
			assert.equal(r1.state, "ready");
			r1:run(4);
			assert.equal(r1.state, "ready");

			assert.equal(r1.state, "ready");
			--for k, v in ipairs(l1) do print(k,v) end
		end);
	end);
end);
