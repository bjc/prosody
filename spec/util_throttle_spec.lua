

-- Mock util.time
local now = 0; -- wibbly-wobbly... timey-wimey... stuff
local function later(n)
	now = now + n; -- time passes at a different rate
end
package.loaded["util.time"] = {
	now = function() return now; end
}


local throttle = require "util.throttle";

describe("util.sasl.scram", function()
	describe("#Hi()", function()
		it("should work", function()
			local a = throttle.create(3, 10);

			assert.are.equal(a:poll(1), true);  -- 3 -> 2
			assert.are.equal(a:poll(1), true);  -- 2 -> 1
			assert.are.equal(a:poll(1), true);  -- 1 -> 0
			assert.are.equal(a:poll(1), false); -- MEEP, out of credits!
			later(1);                       -- ... what about
			assert.are.equal(a:poll(1), false); -- now? - Still no!
			later(9);                       -- Later that day
			assert.are.equal(a:poll(1), true);  -- Should be back at 3 credits ... 2
		end);
	end);
end);
