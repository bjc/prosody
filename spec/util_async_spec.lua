local async = require "util.async";
local match = require "luassert.match";

describe("util.async", function()
	local debug = false;
	local print = print;
	if debug then
		require "util.logger".add_simple_sink(print);
	else
		print = function () end
	end

	local function mock_watchers(event_log)
		local function generic_logging_watcher(name)
			return function (...)
				table.insert(event_log, { name = name, n = select("#", ...)-1, select(2, ...) });
			end;
		end;
		return setmetatable(mock{
			ready = generic_logging_watcher("ready");
			waiting = generic_logging_watcher("waiting");
			error = generic_logging_watcher("error");
		}, {
			__index = function (_, event)
				-- Unexpected watcher called
				assert(false, "unexpected watcher called: "..event);
			end;
		})
	end

	local function new(func)
		local event_log = {};
		local spy_func = spy.new(func);
		return async.runner(spy_func, mock_watchers(event_log)), spy_func, event_log;
	end
	describe("#runner", function()
		it("should work", function()
			local r = new(function (item) assert(type(item) == "number") end);
			r:run(1);
			r:run(2);
		end);

		it("should be ready after creation", function ()
			local r = new(function () end);
			assert.equal(r.state, "ready");
		end);

		it("should do nothing if the queue is empty", function ()
			local did_run;
			local r = new(function () did_run = true end);
			r:run();
			assert.equal(r.state, "ready");
			assert.is_nil(did_run);
			r:run("hello");
			assert.is_true(did_run);
		end);

		it("should support queuing work items without running", function ()
			local did_run;
			local r = new(function () did_run = true end);
			r:enqueue("hello");
			assert.equal(r.state, "ready");
			assert.is_nil(did_run);
			r:run();
			assert.is_true(did_run);
		end);

		it("should support queuing multiple work items", function ()
			local last_item;
			local r, s = new(function (item) last_item = item; end);
			r:enqueue("hello");
			r:enqueue("there");
			r:enqueue("world");
			assert.equal(r.state, "ready");
			r:run();
			assert.equal(r.state, "ready");
			assert.spy(s).was.called(3);
			assert.equal(last_item, "world");
		end);

		it("should support all simple data types", function ()
			local last_item;
			local r, s = new(function (item) last_item = item; end);
			local values = { {}, 123, "hello", true, false };
			for i = 1, #values do
				r:enqueue(values[i]);
			end
			assert.equal(r.state, "ready");
			r:run();
			assert.equal(r.state, "ready");
			assert.spy(s).was.called(#values);
			for i = 1, #values do
				assert.spy(s).was.called_with(values[i]);
			end
			assert.equal(last_item, values[#values]);
		end);

		it("should work with no parameters", function ()
			local item = "fail";
			local r = async.runner();
			local f = spy.new(function () item = "success"; end);
			r:run(f);
			assert.spy(f).was.called();
			assert.equal(item, "success");
		end);

		it("supports a default error handler", function ()
			local item = "fail";
			local r = async.runner();
			local f = spy.new(function () error("test error"); end);
			assert.error_matches(function ()
				r:run(f);
			end, "test error");
			assert.spy(f).was.called();
			assert.equal(item, "fail");
		end);

		describe("#errors", function ()
			describe("should notify", function ()
				local last_processed_item, last_error;
				local r;
				r = async.runner(function (item)
					if item == "error" then
						error({ e = "test error" });
					end
					last_processed_item = item;
				end, mock{
					ready = function () end;
					waiting = function () end;
					error = function (runner, err)
						assert.equal(r, runner);
						last_error = err;
					end;
				});

				-- Simple item, no error
				r:run("hello");
				assert.equal(r.state, "ready");
				assert.equal(last_processed_item, "hello");
				assert.spy(r.watchers.ready).was_not.called();
				assert.spy(r.watchers.error).was_not.called();

				-- Trigger an error inside the runner
				assert.equal(last_error, nil);
				r:run("error");
				test("the correct watcher functions", function ()
					-- Only the error watcher should have been called
					assert.spy(r.watchers.ready).was_not.called();
					assert.spy(r.watchers.waiting).was_not.called();
					assert.spy(r.watchers.error).was.called(1);
				end);
				test("with the correct error", function ()
					-- The error watcher state should be correct, to
					-- demonstrate the error was passed correctly
					assert.is_table(last_error);
					assert.equal(last_error.e, "test error");
					last_error = nil;
				end);
				assert.equal(r.state, "ready");
				assert.equal(last_processed_item, "hello");
			end);

			do
				local last_processed_item, last_error;
				local r;
				local wait, done;
				r = async.runner(function (item)
					if item == "error" then
						error({ e = "test error" });
					elseif item == "wait" then
						wait, done = async.waiter();
						wait();
						error({ e = "post wait error" });
					end
					last_processed_item = item;
				end, mock({
					ready = function () end;
					waiting = function () end;
					error = function (runner, err)
						assert.equal(r, runner);
						last_error = err;
					end;
				}));

				randomize(false); --luacheck: ignore 113/randomize

				it("should not be fatal to the runner", function ()
					r:run("world");
					assert.equal(r.state, "ready");
					assert.spy(r.watchers.ready).was_not.called();
					assert.equal(last_processed_item, "world");
				end);
				it("should work despite a #waiter", function ()
					-- This test covers an important case where a runner
					-- throws an error while being executed outside of the
					-- main loop. This happens when it was blocked ('waiting'),
					-- and then released (via a call to done()).
					last_error = nil;
					r:run("wait");
					assert.equal(r.state, "waiting");
					assert.spy(r.watchers.waiting).was.called(1);
					done();
					-- At this point an error happens (state goes error->ready)
					assert.equal(r.state, "ready");
					assert.spy(r.watchers.error).was.called(1);
					assert.spy(r.watchers.ready).was.called(1);
					assert.is_table(last_error);
					assert.equal(last_error.e, "post wait error");
					last_error = nil;
					r:run("hello again");
					assert.spy(r.watchers.ready).was.called(1);
					assert.spy(r.watchers.waiting).was.called(1);
					assert.spy(r.watchers.error).was.called(1);
					assert.equal(r.state, "ready");
					assert.equal(last_processed_item, "hello again");
				end);
			end

			it("should continue to process work items", function ()
				local last_item;
				local runner, runner_func = new(function (item)
					if item == "error" then
						error("test error");
					end
					last_item = item;
				end);
				runner:enqueue("one");
				runner:enqueue("error");
				runner:enqueue("two");
				runner:run();
				assert.equal(runner.state, "ready");
				assert.spy(runner_func).was.called(3);
				assert.spy(runner.watchers.error).was.called(1);
				assert.spy(runner.watchers.ready).was.called(0);
				assert.spy(runner.watchers.waiting).was.called(0);
				assert.equal(last_item, "two");
			end);

			it("should continue to process work items during resume", function ()
				local wait, done, last_item;
				local runner, runner_func = new(function (item)
					if item == "wait-error" then
						wait, done = async.waiter();
						wait();
						error("test error");
					end
					last_item = item;
				end);
				runner:enqueue("one");
				runner:enqueue("wait-error");
				runner:enqueue("two");
				runner:run();
				done();
				assert.equal(runner.state, "ready");
				assert.spy(runner_func).was.called(3);
				assert.spy(runner.watchers.error).was.called(1);
				assert.spy(runner.watchers.waiting).was.called(1);
				assert.spy(runner.watchers.ready).was.called(1);
				assert.equal(last_item, "two");
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

			local r = new(function (item)
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
			local r = new(function (item)
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
			local r = new(function (item)
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
			local r = new(function (item)
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
			local r1 = new(function (item)
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
			local r2 = new(function (item)
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
			local r1 = new(function (item)
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
			local r2 = new(function (item)
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
		end);

		-- luacheck: ignore 211/rf
		-- FIXME what's rf?
		it("should support multiple done() calls", function ()
			local processed_item;
			local wait, done;
			local r, rf = new(function (item)
				wait, done = async.waiter(4);
				wait();
				processed_item = item;
			end);
			r:run("test");
			for _ = 1, 3 do
				done();
				assert.equal(r.state, "waiting");
				assert.is_nil(processed_item);
			end
			done();
			assert.equal(r.state, "ready");
			assert.equal(processed_item, "test");
			assert.spy(r.watchers.error).was_not.called();
		end);

		it("should not allow done() to be called more than specified", function ()
			local processed_item;
			local wait, done;
			local r, rf = new(function (item)
				wait, done = async.waiter(4);
				wait();
				processed_item = item;
			end);
			r:run("test");
			for _ = 1, 4 do
				done();
			end
			assert.has_error(done);
			assert.equal(r.state, "ready");
			assert.equal(processed_item, "test");
			assert.spy(r.watchers.error).was_not.called();
		end);

		it("should allow done() to be called before wait()", function ()
			local processed_item;
			local r, rf = new(function (item)
				local wait, done = async.waiter();
				done();
				wait();
				processed_item = item;
			end);
			r:run("test");
			assert.equal(processed_item, "test");
			assert.equal(r.state, "ready");
			-- Since the observable state did not change,
			-- the watchers should not have been called
			assert.spy(r.watchers.waiting).was_not.called();
			assert.spy(r.watchers.ready).was_not.called();
		end);
	end);

	describe("#ready()", function ()
		it("should return false outside an async context", function ()
			assert.falsy(async.ready());
		end);
		it("should return true inside an async context", function ()
			local r = new(function ()
				assert.truthy(async.ready());
			end);
			r:run(true);
			assert.spy(r.func).was.called();
			assert.spy(r.watchers.error).was_not.called();
		end);
	end);

	describe("#sleep()", function ()
		after_each(function ()
			-- Restore to default
			async.set_schedule_function(nil);
		end);

		it("should fail if no scheduler configured", function ()
			local r = new(function ()
				async.sleep(5);
			end);
			r:run(true);
			assert.spy(r.watchers.error).was.called();

			-- Set dummy scheduler
			async.set_schedule_function(function () end);

			local r2 = new(function ()
				async.sleep(5);
			end);
			r2:run(true);
			assert.spy(r2.watchers.error).was_not.called();
		end);
		it("should work", function ()
			local queue = {};
			local add_task = spy.new(function (t, f)
				table.insert(queue, { t, f });
			end);
			async.set_schedule_function(add_task);

			local processed_item;
			local r = new(function (item)
				async.sleep(5);
				processed_item = item;
			end);
			r:run("test");

			-- Nothing happened, because the runner is sleeping
			assert.is_nil(processed_item);
			assert.equal(r.state, "waiting");
			assert.spy(add_task).was_called(1);
			assert.spy(add_task).was_called_with(match.is_number(), match.is_function());
			assert.spy(r.watchers.waiting).was.called();
			assert.spy(r.watchers.ready).was_not.called();

			-- Pretend the timer has triggered, call the handler
			queue[1][2]();

			assert.equal(processed_item, "test");
			assert.equal(r.state, "ready");

			assert.spy(r.watchers.ready).was.called();
		end);
	end);

	describe("#set_nexttick()", function ()
		after_each(function ()
			-- Restore to default
			async.set_nexttick(nil);
		end);
		it("should work", function ()
			local queue = {};
			local nexttick = spy.new(function (f)
				assert.is_function(f);
				table.insert(queue, f);
			end);
			async.set_nexttick(nexttick);

			local processed_item;
			local wait, done;
			local r = new(function (item)
				wait, done = async.waiter();
				wait();
				processed_item = item;
			end);
			r:run("test");

			-- Nothing happened, because the runner is waiting
			assert.is_nil(processed_item);
			assert.equal(r.state, "waiting");
			assert.spy(nexttick).was_called(0);
			assert.spy(r.watchers.waiting).was.called();
			assert.spy(r.watchers.ready).was_not.called();

			-- Mark the runner as ready, it should be scheduled for
			-- the next tick
			done();

			assert.spy(nexttick).was_called(1);
			assert.spy(nexttick).was_called_with(match.is_function());
			assert.equal(1, #queue);

			-- Pretend it's the next tick - call the pending function
			queue[1]();

			assert.equal(processed_item, "test");
			assert.equal(r.state, "ready");
			assert.spy(r.watchers.ready).was.called();
		end);
	end);
end);
