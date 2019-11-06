local array = require "util.array";
describe("util.array", function ()
	describe("creation", function ()
		describe("from table", function ()
			it("works", function ()
				local a = array({"a", "b", "c"});
				assert.same({"a", "b", "c"}, a);
			end);
		end);

		describe("from iterator", function ()
			it("works", function ()
				-- collects the first value, ie the keys
				local a = array(ipairs({true, true, true}));
				assert.same({1, 2, 3}, a);
			end);
		end);

		describe("collect", function ()
			it("works", function ()
				-- collects the first value, ie the keys
				local a = array.collect(ipairs({true, true, true}));
				assert.same({1, 2, 3}, a);
			end);
		end);

	end);

	describe("metatable", function ()
		describe("operator", function ()
			describe("addition", function ()
				it("works", function ()
					local a = array({ "a", "b" });
					local b = array({ "c", "d" });
					assert.same({"a", "b", "c", "d"}, a + b);
				end);
			end);

			describe("equality", function ()
				it("works", function ()
					local a1 = array({ "a", "b" });
					local a2 = array({ "a", "b" });
					local b = array({ "c", "d" });
					assert.truthy(a1 == a2);
					assert.falsy(a1 == b);
				end);
			end);

			describe("division", function ()
				it("works", function ()
					local a = array({ "a", "b", "c" });
					local b = a / function (i) if i ~= "b" then return i .. "x" end end;
					assert.same({ "ax", "cx" }, b);
				end);
			end);

		end);
	end);

	describe("methods", function ()
		describe("map", function ()
			it("works", function ()
				local a = array({ "a", "b", "c" });
				local b = a:map(string.upper);
				assert.same({ "A", "B", "C" }, b);
			end);
		end);

		describe("filter", function ()
			it("works", function ()
				local a = array({ "a", "b", "c" });
				a:filter(function (i) return i ~= "b" end);
				assert.same({ "a", "c" }, a);
			end);
		end);

		describe("sort", function ()
			it("works", function ()
				local a = array({ 5, 4, 3, 1, 2, });
				a:sort();
				assert.same({ 1, 2, 3, 4, 5, }, a);
			end);
		end);

		describe("unique", function ()
			it("works", function ()
				local a = array({ "a", "b", "c", "c", "a", "b" });
				a:unique();
				assert.same({ "a", "b", "c" }, a);
			end);
		end);

		describe("pluck", function ()
			it("works", function ()
				local a = array({ { a = 1, b = -1 }, { a = 2, b = -2 }, });
				a:pluck("a");
				assert.same({ 1, 2 }, a);
			end);
		end);


		describe("reverse", function ()
			it("works", function ()
				local a = array({ "a", "b", "c" });
				a:reverse();
				assert.same({ "c", "b", "a" }, a);
			end);
		end);

		-- TODO :shuffle

		describe("append", function ()
			it("works", function ()
				local a = array({ "a", "b", "c" });
				a:append(array({ "d", "e", }));
				assert.same({ "a", "b", "c", "d", "e" }, a);
			end);
		end);

		describe("push", function ()
			it("works", function ()
				local a = array({ "a", "b", "c" });
				a:push("d"):push("e");
				assert.same({ "a", "b", "c", "d", "e" }, a);
			end);
		end);

		describe("pop", function ()
			it("works", function ()
				local a = array({ "a", "b", "c" });
				assert.equal("c", a:pop());
				assert.same({ "a", "b", }, a);
			end);
		end);

		describe("concat", function ()
			it("works", function ()
				local a = array({ "a", "b", "c" });
				assert.equal("a,b,c", a:concat(","));
			end);
		end);

		describe("length", function ()
			it("works", function ()
				local a = array({ "a", "b", "c" });
				assert.equal(3, a:length());
			end);
		end);

	end);

	-- TODO The various array.foo(array ina, array outa) functions
end);

