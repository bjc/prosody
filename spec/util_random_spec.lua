
local random = require "util.random";

describe("util.random", function()
	describe("#bytes()", function()
		it("should return a string", function()
			assert.is_string(random.bytes(16));
		end);

		it("should return the requested number of bytes", function()
			-- Makes no attempt at testing how random the bytes are,
			-- just that it returns the number of bytes requested

			for i = 1, 255 do
				assert.are.equal(i, #random.bytes(i));
			end
		end);
	end);
end);
