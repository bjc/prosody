local dbuffer = require "util.dbuffer";
describe("util.dbuffer", function ()
	describe("#new", function ()
		it("has a constructor", function ()
			assert.Function(dbuffer.new);
		end);
		it("can be created", function ()
			assert.truthy(dbuffer.new());
			assert.truthy(dbuffer.new(1));
			assert.truthy(dbuffer.new(1024));
		end);
		it("won't create an empty buffer", function ()
			assert.falsy(dbuffer.new(0));
		end);
		it("won't create a negatively sized buffer", function ()
			assert.falsy(dbuffer.new(-1));
		end);
	end);
	describe(":write", function ()
		local b = dbuffer.new(10, 3);
		it("works", function ()
			assert.truthy(b:write("hi"));
		end);
		it("fails when the buffer is full", function ()
			local ret = b:write(" there world, this is a long piece of data");
			assert.is_falsy(ret);
		end);
		it("works when max_chunks is reached", function ()
			-- Chunks are an optimization, dbuffer should collapse chunks when needed
			for _ = 1, 8 do
				assert.truthy(b:write("!"));
			end
			assert.falsy(b:write("!")); -- Length reached
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
		it("fails when there is not enough data in the buffer", function ()
			local b = dbuffer.new(12);
			b:write("hello");
			b:write(" ");
			b:write("world");
			assert.is_falsy(b:read(12));
			assert.is_falsy(b:read(13));
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
		it("works across chunks", function ()
			assert.truthy(b:write("hello"));
			assert.truthy(b:write(" "));
			assert.truthy(b:write("world"));
			assert.truthy(b:discard(3));
			assert.equal(8, b:length());
			assert.truthy(b:discard(3));
			assert.equal(5, b:length());
			assert.equal("world", b:read(5));
		end);
		it("can discard the entire buffer", function ()
			assert.equal(b:len(), 0);
			assert.truthy(b:write("hello world"));
			assert.truthy(b:discard(11));
			assert.equal(0, b:len());
			assert.truthy(b:write("hello world"));
			assert.truthy(b:discard(12));
			assert.equal(0, b:len());
			assert.truthy(b:write("hello world"));
			assert.truthy(b:discard(128));
			assert.equal(0, b:len());
		end);
		it("works on an empty buffer", function ()
			assert.truthy(dbuffer.new():discard());
			assert.truthy(dbuffer.new():discard(0));
			assert.truthy(dbuffer.new():discard(1));
		end);
	end);

	describe(":collapse()", function ()
		it("works", function ()
			local b = dbuffer.new();
			b:write("hello");
			b:write(" ");
			b:write("world");
			b:collapse(6);
			local ret, bytes = b:read_chunk();
			assert.equal("hello ", ret);
			assert.equal(6, bytes);
		end);
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

		it("works on an empty buffer", function ()
			local b = dbuffer.new();
			assert.equal("", b:sub(1, 12));
		end);
	end);

	describe(":byte", function ()
		-- Helper function to compare buffer:byte() with string:byte()
		local s = "hello world"
		local function test_byte(b, x, y)
			local string_result, buffer_result = {s:byte(x, y)}, {b:byte(x, y)};
			assert.same(
				string_result,
				buffer_result,
				("buffer:byte(%s, %s) does not match string:byte()"):format(x and ("%d"):format(x) or "nil", y and ("%d"):format(y) or "nil")
			);
		end

		it("is equivalent to string:byte", function ()
			local b = dbuffer.new(11);
			assert.truthy(b:write(s));
			test_byte(b, 1);
			test_byte(b, 3);
			test_byte(b, -1);
			test_byte(b, -3);
			test_byte(b, nil, 5);
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
