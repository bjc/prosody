local format = require "util.format".format;

describe("util.format", function()
	describe("#format()", function()
		it("should work", function()
			assert.equal(format("%s", "hello"), "hello");
			assert.equal(format("%s"), "<nil>");
			assert.equal(format("%s", true), "true");
			assert.equal(format("%d", true), "[true]");
			assert.equal(format("%%", true), "% [true]");
		end);
	end);
end);
