-- This tests the format, not the randomness

local uuid = require "util.uuid";

describe("util.uuid", function()
	describe("#generate()", function()
		it("should work follow the UUID pattern", function()
			-- https://www.rfc-editor.org/rfc/rfc4122.html#section-4.4

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

			assert.truthy(uuid.generate() ~= uuid.generate(), "does not generate the same UUIDv4 twice")
		end);
	end);
	describe("#v7", function()
		it("should also follow the UUID pattern", function()
			local pattern = "^" .. table.concat({
					string.rep("%x", 8),
					string.rep("%x", 4),
					"7" .. -- version
					string.rep("%x", 3),
					"[89ab]" .. -- reserved bits of 1 and 0
					string.rep("%x", 3),
					string.rep("%x", 12),
				}, "%-") .. "$";

			local one = uuid.v7(); -- one before the loop to ensure some time passes
			for _ = 1, 100 do
				assert.is_string(uuid.v7():match(pattern));
			end
			-- one after the loop when some time should have passed
			assert.truthy(one < uuid.v7(), "should be ordererd")
		end);
	end);
end);
