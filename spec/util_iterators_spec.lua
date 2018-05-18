local iter = require "util.iterators";
local set = require "util.set";

describe("util.iterators", function ()
	describe("join", function ()
		it("should produce a joined iterator", function ()
			local expect = { "a", "b", "c", 1, 2, 3 };
			local output = {};
			for x in iter.join(iter.values({"a", "b", "c"})):append(iter.values({1, 2, 3})) do
				table.insert(output, x);
			end
			assert.same(output, expect);
		end);
	end);
end);
