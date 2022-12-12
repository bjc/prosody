describe("util.jsonpointer", function()
	local json, jp;
	setup(function()
		json = require "util.json";
		jp = require "util.jsonpointer";
	end)
	describe("resolve()", function()
		local example;
		setup(function()
			example = json.decode([[{
				"foo": ["bar", "baz"],
				"": 0,
				"a/b": 1,
				"c%d": 2,
				"e^f": 3,
				"g|h": 4,
				"i\\j": 5,
				"k\"l": 6,
				" ": 7,
				"m~n": 8
		 }]])
		end)
		it("works", function()
			assert.is_nil(jp.resolve("string", "/string"))
			assert.same(example, jp.resolve(example, ""));
			assert.same({ "bar", "baz" }, jp.resolve(example, "/foo"));
			assert.same("bar", jp.resolve(example, "/foo/0"));
			assert.same(nil, jp.resolve(example, "/foo/-"));
			assert.same(0, jp.resolve(example, "/"));
			assert.same(1, jp.resolve(example, "/a~1b"));
			assert.same(2, jp.resolve(example, "/c%d"));
			assert.same(3, jp.resolve(example, "/e^f"));
			assert.same(4, jp.resolve(example, "/g|h"));
			assert.same(5, jp.resolve(example, "/i\\j"));
			assert.same(6, jp.resolve(example, "/k\"l"));
			assert.same(7, jp.resolve(example, "/ "));
			assert.same(8, jp.resolve(example, "/m~0n"));
		end)
	end)
end)
