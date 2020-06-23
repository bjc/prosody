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

	describe(":discard", function ()
		local b = rb.new();
		it("works", function ()
			assert.truthy(b:write("hello world"));
			assert.truthy(b:discard(6));
			assert.equal(5, #b);
			assert.equal("world", b:read(5));
		end);
	end);

	describe(":sub", function ()
		-- Helper function to compare buffer:sub() with string:sub()
		local function test_sub(b, x, y)
			local s = b:read(#b, true);
			local string_result, buffer_result = s:sub(x, y), b:sub(x, y);
			assert.equals(string_result, buffer_result, ("buffer:sub(%d, %s) does not match string:sub()"):format(x, y and ("%d"):format(y) or "nil"));
		end

		it("works", function ()
			local b = rb.new();
			b:write("hello world");
			assert.equals("hello", b:sub(1, 5));
		end);

		it("supports optional end parameter", function ()
			local b = rb.new();
			b:write("hello world");
			assert.equals("hello world", b:sub(1));
			assert.equals("world", b:sub(-5));
		end);

		it("is equivalent to string:sub", function ()
			local b = rb.new(6);
			b:write("foobar");
			b:read(3);
			b:write("foo");
			for i = -13, 13 do
				for j = -13, 13 do
					test_sub(b, i, j);
				end
			end
		end);
	end);

	describe(":byte", function ()
		-- Helper function to compare buffer:byte() with string:byte()
		local function test_byte(b, x, y)
			local s = b:read(#b, true);
			local string_result, buffer_result = {s:byte(x, y)}, {b:byte(x, y)};
			assert.same(string_result, buffer_result, ("buffer:byte(%d, %s) does not match string:byte()"):format(x, y and ("%d"):format(y) or "nil"));
		end

		it("is equivalent to string:byte", function ()
			local b = rb.new(6);
			b:write("foobar");
			b:read(3);
			b:write("foo");
			test_byte(b, 1);
			test_byte(b, 3);
			test_byte(b, -1);
			test_byte(b, -3);
			for i = -13, 13 do
				for j = -13, 13 do
					test_byte(b, i, j);
				end
			end
		end);
	end);
end);
