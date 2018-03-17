local format = require "util.format".format;

describe("util.format", function()
	describe("#format()", function()
		it("should work", function()
			assert.equal("hello", format("%s", "hello"));
			assert.equal("<nil>", format("%s"));
			assert.equal("true", format("%s", true));
			assert.equal("[true]", format("%d", true));
			assert.equal("% [true]", format("%%", true));
		end);
	end);
end);
