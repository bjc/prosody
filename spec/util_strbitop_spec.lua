local strbitop = require "util.strbitop";
describe("util.strbitop", function ()
	describe("sand()", function ()
		it("works", function ()
			assert.equal(string.rep("Aa", 100), strbitop.sand(string.rep("a", 200), "Aa"));
		end);
		it("returns empty string if first argument is empty", function ()
			assert.equal("", strbitop.sand("", ""));
			assert.equal("", strbitop.sand("", "key"));
		end);
		it("returns initial string if key is empty", function ()
			assert.equal("hello", strbitop.sand("hello", ""));
		end);
	end);

	describe("sor()", function ()
		it("works", function ()
			assert.equal(string.rep("a", 200), strbitop.sor(string.rep("Aa", 100), "a"));
		end);
		it("returns empty string if first argument is empty", function ()
			assert.equal("", strbitop.sor("", ""));
			assert.equal("", strbitop.sor("", "key"));
		end);
		it("returns initial string if key is empty", function ()
			assert.equal("hello", strbitop.sor("hello", ""));
		end);
	end);

	describe("sxor()", function ()
		it("works", function ()
			assert.equal(string.rep("Aa", 100), strbitop.sxor(string.rep("a", 200), " \0"));
		end);
		it("returns empty string if first argument is empty", function ()
			assert.equal("", strbitop.sxor("", ""));
			assert.equal("", strbitop.sxor("", "key"));
		end);
		it("returns initial string if key is empty", function ()
			assert.equal("hello", strbitop.sxor("hello", ""));
		end);
	end);

	describe("common_prefix_bits()", function ()
		local function B(s)
			assert(#s%8==0, "Invalid test input: B(s): s should be a multiple of 8 bits in length");
			local byte = 0;
			local out_str = {};
			for i = 1, #s do
				local bit_ascii = s:byte(i);
				if bit_ascii == 49 then -- '1'
					byte = byte + 2^((7-(i-1))%8);
				elseif bit_ascii ~= 48 then
					error("Invalid test input: B(s): s should contain only '0' or '1' characters");
				end
				if (i-1)%8 == 7 then
					table.insert(out_str, string.char(byte));
					byte = 0;
				end
			end
			return table.concat(out_str);
		end

		local _cpb = strbitop.common_prefix_bits;
		local function test(a, b)
			local Ba, Bb = B(a), B(b);
			local ret1 = _cpb(Ba, Bb);
			local ret2 = _cpb(Bb, Ba);
			assert(ret1 == ret2, ("parameter order should not make a difference to the result (%s, %s) = %d, reversed = %d"):format(a, b, ret1, ret2));
			return ret1;
		end

		it("works on single bytes", function ()
			assert.equal(0, test("00000000", "11111111"));
			assert.equal(1, test("10000000", "11111111"));
			assert.equal(0, test("01000000", "11111111"));
			assert.equal(0, test("01000000", "11111111"));
			assert.equal(8, test("11111111", "11111111"));
		end);

		it("works on multiple bytes", function ()
			for i = 0, 16 do
				assert.equal(i, test(string.rep("1", i)..string.rep("0", 16-i), "1111111111111111"));
			end
		end);
	end);
end);
