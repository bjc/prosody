-- This tests the format, not the randomness

local uuid = require "util.uuid";

describe("util.uuid", function()
	describe("#generate()", function()
		it("should work follow the UUID pattern", function()
			-- https://tools.ietf.org/html/rfc4122#section-4.4

			local pattern = "^" .. table.concat({
				string.rep("%x", 8),
				string.rep("%x", 4),
				"4" .. -- version
				string.rep("%x", 3),
				"[89ab]" .. -- reserved bits of 1 and 0
				string.rep("%x", 3),
				string.rep("%x", 12),
			}, "%-") .. "$";

			for _ = 1, 100 do
				assert.is_string(uuid.generate():match(pattern));
			end
		end);
	end);

	describe("#seed()", function()
		it("should return nothing", function()
			assert.is_nil(uuid.seed("random string here"), "seed doesn't return anything");
		end);
	end);
end);
