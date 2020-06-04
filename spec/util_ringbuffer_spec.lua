local rb = require "util.ringbuffer";
describe("util.ringbuffer", function ()
	describe("#new", function ()
		it("has a constructor", function ()
			assert.Function(rb.new);
		end);
		it("can be created", function ()
			assert.truthy(rb.new());
		end);
		it("won't create an empty buffer", function ()
			assert.has_error(function ()
				rb.new(0);
			end);
		end);
		it("won't create a negatively sized buffer", function ()
			assert.has_error(function ()
				rb.new(-1);
			end);
		end);
	end);
	describe(":write", function ()
		local b = rb.new();
		it("works", function ()
			assert.truthy(b:write("hi"));
		end);
	end);
end);
