local iter = require "util.iterators";

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
		it("should work with only a single iterator", function ()
			local expect = { "a", "b", "c" };
			local output = {};
			for x in iter.join(iter.values({"a", "b", "c"})) do
				table.insert(output, x);
			end
			assert.same(output, expect);
		end);
	end);

	describe("sorted_pairs", function ()
		it("should produce sorted pairs", function ()
			local orig = { b = 1, c = 2, a = "foo", d = false };
			local n, last_key = 0, nil;
			for k, v in iter.sorted_pairs(orig) do
				n = n + 1;
				if last_key then
					assert(k > last_key, "Expected "..k.." > "..last_key)
				end
				assert.equal(orig[k], v);
				last_key = k;
			end
			assert.equal("d", last_key);
			assert.equal(4, n);
		end);

		it("should allow a custom sort function", function ()
			local orig = { b = 1, c = 2, a = "foo", d = false };
			local n, last_key = 0, nil;
			for k, v in iter.sorted_pairs(orig, function (a, b) return a > b end) do
				n = n + 1;
				if last_key then
					assert(k < last_key, "Expected "..k.." > "..last_key)
				end
				assert.equal(orig[k], v);
				last_key = k;
			end
			assert.equal("a", last_key);
			assert.equal(4, n);
		end);
	end);
end);
