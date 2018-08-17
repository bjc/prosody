describe("util.time", function ()
	local time;
	setup(function ()
		time = require "util.time";
	end);
	describe("now()", function ()
		it("exists", function ()
			assert.is_function(time.now);
		end);
		it("returns a number", function ()
			assert.is_number(time.now());
		end);
	end);
	describe("monotonic()", function ()
		it("exists", function ()
			assert.is_function(time.monotonic);
		end);
		it("returns a number", function ()
			assert.is_number(time.monotonic());
		end);
		it("time goes in one direction", function ()
			local a = time.monotonic();
			local b	= time.monotonic();
			assert.truthy(a <= b);
		end);
	end);
end);




