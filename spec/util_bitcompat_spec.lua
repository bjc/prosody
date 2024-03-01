describe("util.bitcompat", function ()
	-- bitcompat will pass through to an appropriate implementation. Our
	-- goal here is to check that whatever implementation is in use passes
	-- these basic sanity checks.

	local bit = require "util.bitcompat";

	it("bor works", function ()
		assert.equal(0xF0FF, bit.bor(0xF000, 0x00F0, 0x000F));
	end);

	it("band works", function ()
		assert.equal(0x0F, bit.band(0xFF, 0x1F, 0x0F));
	end);

	it("bxor works", function ()
		assert.equal(0x13, bit.bxor(0x10, 0x0F, 0x0C));
	end);

	it("rshift works", function ()
		assert.equal(0x0F, bit.rshift(0xFF, 4));
	end);

	it("lshift works", function ()
		assert.equal(0xFF00, bit.lshift(0xFF, 8));
	end);

	it("bnot works", function ()
		assert.equal(0x0000FF00, bit.band(0xFFFFFFFF, bit.bnot(0xFFFF00FF)));
	end);
end);
