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
end);
