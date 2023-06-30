
local cache = require "util.cache";

describe("util.cache", function()
	describe("#new()", function()
		it("should work", function()
			do
				local c = cache.new(1);
				assert.is_not_nil(c);

				assert.has_error(function ()
					cache.new(0);
				end);
				assert.has_error(function ()
					cache.new(-1);
				end);
				assert.has_error(function ()
					cache.new("foo");
				end);
			end

			local c = cache.new(5);

			local function expect_kv(key, value, actual_key, actual_value)
				assert.are.equal(key, actual_key, "key incorrect");
				assert.are.equal(value, actual_value, "value incorrect");
			end

			expect_kv(nil, nil, c:head());
			expect_kv(nil, nil, c:tail());

			assert.are.equal(c:count(), 0);

			c:set("one", 1)
			assert.are.equal(c:count(), 1);
			expect_kv("one", 1, c:head());
			expect_kv("one", 1, c:tail());

			c:set("two", 2)
			expect_kv("two", 2, c:head());
			expect_kv("one", 1, c:tail());

			c:set("three", 3)
			expect_kv("three", 3, c:head());
			expect_kv("one", 1, c:tail());

			c:set("four", 4)
			c:set("five", 5);
			assert.are.equal(c:count(), 5);
			expect_kv("five", 5, c:head());
			expect_kv("one", 1, c:tail());

			c:set("foo", nil);
			assert.are.equal(c:count(), 5);
			expect_kv("five", 5, c:head());
			expect_kv("one", 1, c:tail());

			assert.are.equal(c:get("one"), 1);
			expect_kv("five", 5, c:head());
			expect_kv("one", 1, c:tail());

			assert.are.equal(c:get("two"), 2);
			assert.are.equal(c:get("three"), 3);
			assert.are.equal(c:get("four"), 4);
			assert.are.equal(c:get("five"), 5);

			assert.are.equal(c:get("foo"), nil);
			assert.are.equal(c:get("bar"), nil);

			c:set("six", 6);
			assert.are.equal(c:count(), 5);
			expect_kv("six", 6, c:head());
			expect_kv("two", 2, c:tail());

			assert.are.equal(c:get("one"), nil);
			assert.are.equal(c:get("two"), 2);
			assert.are.equal(c:get("three"), 3);
			assert.are.equal(c:get("four"), 4);
			assert.are.equal(c:get("five"), 5);
			assert.are.equal(c:get("six"), 6);

			c:set("three", nil);
			assert.are.equal(c:count(), 4);

			assert.are.equal(c:get("one"), nil);
			assert.are.equal(c:get("two"), 2);
			assert.are.equal(c:get("three"), nil);
			assert.are.equal(c:get("four"), 4);
			assert.are.equal(c:get("five"), 5);
			assert.are.equal(c:get("six"), 6);

			c:set("seven", 7);
			assert.are.equal(c:count(), 5);

			assert.are.equal(c:get("one"), nil);
			assert.are.equal(c:get("two"), 2);
			assert.are.equal(c:get("three"), nil);
			assert.are.equal(c:get("four"), 4);
			assert.are.equal(c:get("five"), 5);
			assert.are.equal(c:get("six"), 6);
			assert.are.equal(c:get("seven"), 7);

			c:set("eight", 8);
			assert.are.equal(c:count(), 5);

			assert.are.equal(c:get("one"), nil);
			assert.are.equal(c:get("two"), nil);
			assert.are.equal(c:get("three"), nil);
			assert.are.equal(c:get("four"), 4);
			assert.are.equal(c:get("five"), 5);
			assert.are.equal(c:get("six"), 6);
			assert.are.equal(c:get("seven"), 7);
			assert.are.equal(c:get("eight"), 8);

			c:set("four", 4);
			assert.are.equal(c:count(), 5);

			assert.are.equal(c:get("one"), nil);
			assert.are.equal(c:get("two"), nil);
			assert.are.equal(c:get("three"), nil);
			assert.are.equal(c:get("four"), 4);
			assert.are.equal(c:get("five"), 5);
			assert.are.equal(c:get("six"), 6);
			assert.are.equal(c:get("seven"), 7);
			assert.are.equal(c:get("eight"), 8);

			c:set("nine", 9);
			assert.are.equal(c:count(), 5);

			assert.are.equal(c:get("one"), nil);
			assert.are.equal(c:get("two"), nil);
			assert.are.equal(c:get("three"), nil);
			assert.are.equal(c:get("four"), 4);
			assert.are.equal(c:get("five"), nil);
			assert.are.equal(c:get("six"), 6);
			assert.are.equal(c:get("seven"), 7);
			assert.are.equal(c:get("eight"), 8);
			assert.are.equal(c:get("nine"), 9);

			do
				local keys = { "nine", "four", "eight", "seven", "six" };
				local values = { 9, 4, 8, 7, 6 };
				local i = 0;
				for k, v in c:items() do
					i = i + 1;
					assert.are.equal(k, keys[i]);
					assert.are.equal(v, values[i]);
				end
				assert.are.equal(i, 5);

				c:set("four", "2+2");
				assert.are.equal(c:count(), 5);

				assert.are.equal(c:get("one"), nil);
				assert.are.equal(c:get("two"), nil);
				assert.are.equal(c:get("three"), nil);
				assert.are.equal(c:get("four"), "2+2");
				assert.are.equal(c:get("five"), nil);
				assert.are.equal(c:get("six"), 6);
				assert.are.equal(c:get("seven"), 7);
				assert.are.equal(c:get("eight"), 8);
				assert.are.equal(c:get("nine"), 9);
			end

			do
				local keys = { "four", "nine", "eight", "seven", "six" };
				local values = { "2+2", 9, 8, 7, 6 };
				local i = 0;
				for k, v in c:items() do
					i = i + 1;
					assert.are.equal(k, keys[i]);
					assert.are.equal(v, values[i]);
				end
				assert.are.equal(i, 5);

				c:set("foo", nil);
				assert.are.equal(c:count(), 5);

				assert.are.equal(c:get("one"), nil);
				assert.are.equal(c:get("two"), nil);
				assert.are.equal(c:get("three"), nil);
				assert.are.equal(c:get("four"), "2+2");
				assert.are.equal(c:get("five"), nil);
				assert.are.equal(c:get("six"), 6);
				assert.are.equal(c:get("seven"), 7);
				assert.are.equal(c:get("eight"), 8);
				assert.are.equal(c:get("nine"), 9);
			end

			do
				local keys = { "four", "nine", "eight", "seven", "six" };
				local values = { "2+2", 9, 8, 7, 6 };
				local i = 0;
				for k, v in c:items() do
					i = i + 1;
					assert.are.equal(k, keys[i]);
					assert.are.equal(v, values[i]);
				end
				assert.are.equal(i, 5);

				c:set("four", nil);

				assert.are.equal(c:get("one"), nil);
				assert.are.equal(c:get("two"), nil);
				assert.are.equal(c:get("three"), nil);
				assert.are.equal(c:get("four"), nil);
				assert.are.equal(c:get("five"), nil);
				assert.are.equal(c:get("six"), 6);
				assert.are.equal(c:get("seven"), 7);
				assert.are.equal(c:get("eight"), 8);
				assert.are.equal(c:get("nine"), 9);
			end

			do
				local keys = { "nine", "eight", "seven", "six" };
				local values = { 9, 8, 7, 6 };
				local i = 0;
				for k, v in c:items() do
					i = i + 1;
					assert.are.equal(k, keys[i]);
					assert.are.equal(v, values[i]);
				end
				assert.are.equal(i, 4);
			end

			do
				local evicted_key, evicted_value;
				local c2 = cache.new(3, function (_key, _value)
					evicted_key, evicted_value = _key, _value;
				end);
				local function set(k, v, should_evict_key, should_evict_value)
					evicted_key, evicted_value = nil, nil;
					c2:set(k, v);
					assert.are.equal(evicted_key, should_evict_key);
					assert.are.equal(evicted_value, should_evict_value);
				end
				set("a", 1)
				set("a", 1)
				set("a", 1)
				set("a", 1)
				set("a", 1)

				set("b", 2)
				set("c", 3)
				set("b", 2)
				set("d", 4, "a", 1)
				set("e", 5, "c", 3)
			end

			do
				local evicted_key, evicted_value;
				local c3 = cache.new(1, function (_key, _value)
					evicted_key, evicted_value = _key, _value;
					if _key == "a" then
						-- Sanity check for what we're evicting
						assert.are.equal(_key, "a");
						assert.are.equal(_value, 1);
						-- We're going to block eviction of this key/value, so set to nil...
						evicted_key, evicted_value = nil, nil;
						-- Returning false to block eviction
						return false
					end
				end);
				local function set(k, v, should_evict_key, should_evict_value)
					evicted_key, evicted_value = nil, nil;
					local ret = c3:set(k, v);
					assert.are.equal(evicted_key, should_evict_key);
					assert.are.equal(evicted_value, should_evict_value);
					return ret;
				end
				set("a", 1)
				set("a", 1)
				set("a", 1)
				set("a", 1)
				set("a", 1)

				-- Our on_evict prevents "a" from being evicted, causing this to fail...
				assert.are.equal(set("b", 2), false, "Failed to prevent eviction, or signal result");

				expect_kv("a", 1, c3:head());
				expect_kv("a", 1, c3:tail());

				-- Check the final state is what we expect
				assert.are.equal(c3:get("a"), 1);
				assert.are.equal(c3:get("b"), nil);
				assert.are.equal(c3:count(), 1);
			end


			local c4 = cache.new(3, false);

			assert.are.equal(c4:set("a", 1), true);
			assert.are.equal(c4:set("a", 1), true);
			assert.are.equal(c4:set("a", 1), true);
			assert.are.equal(c4:set("a", 1), true);
			assert.are.equal(c4:set("b", 2), true);
			assert.are.equal(c4:set("c", 3), true);
			assert.are.equal(c4:set("d", 4), false);
			assert.are.equal(c4:set("d", 4), false);
			assert.are.equal(c4:set("d", 4), false);

			expect_kv("c", 3, c4:head());
			expect_kv("a", 1, c4:tail());

			local c5 = cache.new(3, function (k, v) --luacheck: ignore 212/v
				if k == "a" then
					return nil;
				elseif k == "b" then
					return true;
				end
				return false;
			end);

			assert.are.equal(c5:set("a", 1), true);
			assert.are.equal(c5:set("a", 1), true);
			assert.are.equal(c5:set("a", 1), true);
			assert.are.equal(c5:set("a", 1), true);
			assert.are.equal(c5:set("b", 2), true);
			assert.are.equal(c5:set("c", 3), true);
			assert.are.equal(c5:set("d", 4), true); -- "a" evicted (cb returned nil)
			assert.are.equal(c5:set("d", 4), true); -- nop
			assert.are.equal(c5:set("d", 4), true); -- nop
			assert.are.equal(c5:set("e", 5), true); -- "b" evicted (cb returned true)
			assert.are.equal(c5:set("f", 6), false); -- "c" won't evict (cb returned false)

			expect_kv("e", 5, c5:head());
			expect_kv("c", 3, c5:tail());

		end);

		it(":table works", function ()
			local t = cache.new(3):table();
			assert.is.table(t);
			t["a"] = "1";
			assert.are.equal(t["a"], "1");
			t["b"] = "2";
			assert.are.equal(t["b"], "2");
			t["c"] = "3";
			assert.are.equal(t["c"], "3");
			t["d"] = "4";
			assert.are.equal(t["d"], "4");
			assert.are.equal(t["a"], nil);

				local i = spy.new(function () end);
				for k, v in pairs(t) do
					i(k,v)
				end
				assert.spy(i).was_called();
				assert.spy(i).was_called_with("b", "2");
				assert.spy(i).was_called_with("c", "3");
				assert.spy(i).was_called_with("d", "4");
		end);

		local function vs(t)
			local vs_ = {};
			for v in t:values() do
				vs_[#vs_+1] = v;
			end
			return vs_;
		end

		it(":values works", function ()
			local t = cache.new(3);
			t:set("k1", "v1");
			t:set("k2", "v2");
			assert.same({"v2", "v1"}, vs(t));
			t:set("k3", "v3");
			assert.same({"v3", "v2", "v1"}, vs(t));
			t:set("k4", "v4");
			assert.same({"v4", "v3", "v2"}, vs(t));
		end);

		it(":resize works", function ()
			local c = cache.new(5);
			for i = 1, 5 do
				c:set(("k%d"):format(i), ("v%d"):format(i));
			end
			assert.same({"v5", "v4", "v3", "v2", "v1"}, vs(c));
			assert.has_error(function ()
				c:resize(-1);
			end);
			assert.has_error(function ()
				c:resize(0);
			end);
			assert.has_error(function ()
				c:resize("foo");
			end);
			c:resize(3);
			assert.same({"v5", "v4", "v3"}, vs(c));
		end);

		it("eviction stuff", function ()
			local c;
			c = cache.new(4, function(_k,_v)
				if c.size < 10 then
					c:resize(c.size*2);
				end
			end)
			for i = 1,20 do
				c:set(i,i)
			end
			assert.equal(16, c.size);
			assert.is_nil(c:get(1))
			assert.is_nil(c:get(4))
			assert.equal(5, c:get(5))
			assert.equal(20, c:get(20))
			c:resize(4)
			assert.equal(20, c:get(20))
			assert.equal(17, c:get(17))
			assert.is_nil(c:get(10))
		end)
	end);
end);
