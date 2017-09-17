

-- Mock util.time
local now = 0; -- wibbly-wobbly... timey-wimey... stuff
local function later(n)
	now = now + n; -- time passes at a different rate
end
package.loaded["util.time"] = {
	now = function() return now; end
}


local throttle = require "util.throttle";

describe("util.throttle", function()
	describe("#create", function()
		it("should be created with correct values", function()
			now = 5;
			local a = throttle.create(3, 10);
			assert.same(a, { balance = 3, max = 3, rate = 0.3, t = 5 });

			local a = throttle.create(3, 5);
			assert.same(a, { balance = 3, max = 3, rate = 0.6, t = 5 });

			local a = throttle.create(1, 1);
			assert.same(a, { balance = 1, max = 1, rate = 1, t = 5 });

			local a = throttle.create(10, 10);
			assert.same(a, { balance = 10, max = 10, rate = 1, t = 5 });

			local a = throttle.create(10, 1);
			assert.same(a, { balance = 10, max = 10, rate = 10, t = 5 });
		end);
	end);

	describe("#update", function()
		it("does nothing when no time hase passed, even if balance is not full", function()
			now = 5;
			local a = throttle.create(10, 10);
			for i=1,5 do
				a:update();
				assert.same(a, { balance = 10, max = 10, rate = 1, t = 5 });
			end
			a.balance = 0;
			for i=1,5 do
				a:update();
				assert.same(a, { balance = 0, max = 10, rate = 1, t = 5 });
			end
		end);
		it("updates only time when time passes but balance is full", function()
			now = 5;
			local a = throttle.create(10, 10);
			for i=1,5 do
				later(5);
				a:update();
				assert.same(a, { balance = 10, max = 10, rate = 1, t = 5 + i*5 });
			end
		end);
		it("updates balance when balance has room to grow as time passes", function()
			now = 5;
			local a = throttle.create(10, 10);
			a.balance = 0;
			assert.same(a, { balance = 0, max = 10, rate = 1, t = 5 });

			later(1);
			a:update();
			assert.same(a, { balance = 1, max = 10, rate = 1, t = 6 });

			later(3);
			a:update();
			assert.same(a, { balance = 4, max = 10, rate = 1, t = 9 });

			later(10);
			a:update();
			assert.same(a, { balance = 10, max = 10, rate = 1, t = 19 });
		end);
		it("handles 10 x 0.1s updates the same as 1 x 1s update ", function()
			now = 5;
			local a = throttle.create(1, 1);

			a.balance = 0;
			later(1);
			a:update();
			assert.same(a, { balance = 1, max = 1, rate = 1, t = now });

			a.balance = 0;
			for i=1,10 do
				later(0.1);
				a:update();
			end
			assert(math.abs(a.balance - 1) < 0.0001); -- incremental updates cause rouding errors
		end);
	end);

	-- describe("po")

	describe("#poll()", function()
		it("should only allow successful polls until cost is hit", function()
			now = 5;

			local a = throttle.create(3, 10);
			assert.same(a, { balance = 3, max = 3, rate = 0.3, t = 5 });

			assert.is_true(a:poll(1));  -- 3 -> 2
			assert.same(a, { balance = 2, max = 3, rate = 0.3, t = 5 });

			assert.is_true(a:poll(2));  -- 2 -> 1
			assert.same(a, { balance = 0, max = 3, rate = 0.3, t = 5 });

			assert.is_false(a:poll(1)); -- MEEP, out of credits!
			assert.is_false(a:poll(1)); -- MEEP, out of credits!
			assert.same(a, { balance = 0, max = 3, rate = 0.3, t = 5 });
		end);

		it("should not allow polls more than the cost", function()
			now = 0;

			local a = throttle.create(10, 10);
			assert.same(a, { balance = 10, max = 10, rate = 1, t = 0 });

			assert.is_false(a:poll(11));
			assert.same(a, { balance = 10, max = 10, rate = 1, t = 0 });

			assert.is_true(a:poll(6));
			assert.same(a, { balance = 4, max = 10, rate = 1, t = 0 });

			assert.is_false(a:poll(5));
			assert.same(a, { balance = 4, max = 10, rate = 1, t = 0 });

			-- fractional
			assert.is_true(a:poll(3.5));
			assert.same(a, { balance = 0.5, max = 10, rate = 1, t = 0 });

			assert.is_true(a:poll(0.25));
			assert.same(a, { balance = 0.25, max = 10, rate = 1, t = 0 });

			assert.is_false(a:poll(0.3));
			assert.same(a, { balance = 0.25, max = 10, rate = 1, t = 0 });

			assert.is_true(a:poll(0.25));
			assert.same(a, { balance = 0, max = 10, rate = 1, t = 0 });

			assert.is_false(a:poll(0.1));
			assert.same(a, { balance = 0, max = 10, rate = 1, t = 0 });

			assert.is_true(a:poll(0));
			assert.same(a, { balance = 0, max = 10, rate = 1, t = 0 });
		end);
	end);
end);
