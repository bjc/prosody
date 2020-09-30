local units = require "util.human.units";

describe("util.human.units", function ()
	describe("format", function ()
		it("formats numbers with SI units", function ()
			assert.equal("1 km", units.format(1000, "m"));
			assert.equal("1 GJ", units.format(1000000000, "J"));
			assert.equal("1 ms", units.format(1/1000, "s"));
			assert.equal("10 ms", units.format(10/1000, "s"));
			assert.equal("1 ns", units.format(1/1000000000, "s"));
			assert.equal("1 KiB", units.format(1024, "B", 'b'));
			assert.equal("1 MiB", units.format(1024*1024, "B", 'b'));
		end);
	end);
end);
