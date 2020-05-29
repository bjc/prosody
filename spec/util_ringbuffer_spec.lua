local rb = require "util.ringbuffer";
describe("util.ringbuffer", function ()
	describe("#new", function ()
		it("has a constructor", function ()
			assert.Function(rb.new);
		end);
		it("can be created", function ()
			assert.truthy(rb.new());
		end);
	end);
	describe(":write", function ()
		local b = rb.new();
		it("works", function ()
			assert.truthy(b:write("hi"));
		end);
	end);
end);
