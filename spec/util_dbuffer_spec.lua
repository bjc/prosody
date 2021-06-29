local dbuffer = require "util.dbuffer";
describe("util.dbuffer", function ()
	describe("#new", function ()
		it("has a constructor", function ()
			assert.Function(dbuffer.new);
		end);
		it("can be created", function ()
			assert.truthy(dbuffer.new());
		end);
		it("won't create an empty buffer", function ()
			assert.falsy(dbuffer.new(0));
		end);
		it("won't create a negatively sized buffer", function ()
			assert.falsy(dbuffer.new(-1));
		end);
	end);
	describe(":write", function ()
		local b = dbuffer.new();
		it("works", function ()
			assert.truthy(b:write("hi"));
		end);
	end);

	describe(":read", function ()
		it("supports optional bytes parameter", function ()
			-- should return the frontmost chunk
			local b = dbuffer.new();
			assert.truthy(b:write("hello"));
			assert.truthy(b:write(" "));
			assert.truthy(b:write("world"));
			assert.equal("h", b:read(1));

			assert.equal("ello", b:read());
			assert.equal(" ", b:read());
			assert.equal("world", b:read());
		end);
	end);

	describe(":read_until", function ()
		it("works", function ()
			local b = dbuffer.new();
			b:write("hello\n");
			b:write("world");
			b:write("\n");
			b:write("\n\n");
			b:write("stuff");
			b:write("more\nand more");

			assert.equal(nil, b:read_until("."));
			assert.equal(nil, b:read_until("%"));
			assert.equal("hello\n", b:read_until("\n"));
			assert.equal("world\n", b:read_until("\n"));
			assert.equal("\n", b:read_until("\n"));
			assert.equal("\n", b:read_until("\n"));
			assert.equal("stu", b:read(3));
			assert.equal("ffmore\n", b:read_until("\n"));
			assert.equal(nil, b:read_until("\n"));
			assert.equal("and more", b:read_chunk());
		end);
	end);

	describe(":discard", function ()
		local b = dbuffer.new();
		it("works", function ()
			assert.truthy(b:write("hello world"));
			assert.truthy(b:discard(6));
			assert.equal(5, b:length());
			assert.equal(5, b:len());
			assert.equal("world", b:read(5));
		end);
	end);

	describe(":collapse()", function ()
		it("works on an empty buffer", function ()
			local b = dbuffer.new();
			b:collapse();
		end);
	end);

	describe(":sub", function ()
		-- Helper function to compare buffer:sub() with string:sub()
		local s = "hello world";
		local function test_sub(b, x, y)
			local string_result, buffer_result = s:sub(x, y), b:sub(x, y);
			assert.equals(string_result, buffer_result, ("buffer:sub(%d, %s) does not match string:sub()"):format(x, y and ("%d"):format(y) or "nil"));
		end

		it("works", function ()
			local b = dbuffer.new();
			assert.truthy(b:write("hello world"));
			assert.equals("hello", b:sub(1, 5));
		end);

		it("works after discard", function ()
			local b = dbuffer.new(256);
			assert.truthy(b:write("foobar"));
			assert.equals("foobar", b:sub(1, 6));
			assert.truthy(b:discard(3)); -- consume "foo"
			assert.equals("bar", b:sub(1, 3));
		end);

		it("supports optional end parameter", function ()
			local b = dbuffer.new();
			assert.truthy(b:write("hello world"));
			assert.equals("hello world", b:sub(1));
			assert.equals("world", b:sub(-5));
		end);

		it("is equivalent to string:sub", function ()
			local b = dbuffer.new(11);
			assert.truthy(b:write(s));
			for i = -13, 13 do
				for j = -13, 13 do
					test_sub(b, i, j);
				end
			end
		end);
	end);

	describe(":byte", function ()
		-- Helper function to compare buffer:byte() with string:byte()
		local s = "hello world"
		local function test_byte(b, x, y)
			local string_result, buffer_result = {s:byte(x, y)}, {b:byte(x, y)};
			assert.same(string_result, buffer_result, ("buffer:byte(%d, %s) does not match string:byte()"):format(x, y and ("%d"):format(y) or "nil"));
		end

		it("is equivalent to string:byte", function ()
			local b = dbuffer.new(11);
			assert.truthy(b:write(s));
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

		it("works with characters > 127", function ()
			local b = dbuffer.new();
			b:write(string.char(0, 140));
			local r = { b:byte(1, 2) };
			assert.same({ 0, 140 }, r);
		end);

		it("works on an empty buffer", function ()
			local b = dbuffer.new();
			assert.equal("", b:sub(1,1));
		end);
	end);
end);
