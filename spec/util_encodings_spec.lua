
local encodings = require "util.encodings";
local utf8 = assert(encodings.utf8, "no encodings.utf8 module");

describe("util.encodings.utf8", function()
	describe("#valid()", function()
		it("should work", function()

			for line in io.lines("spec/utf8_sequences.txt") do
				local data = line:match(":%s*([^#]+)"):gsub("%s+", ""):gsub("..", function (c) return string.char(tonumber(c, 16)); end)
				local expect = line:match("(%S+):");

				assert(expect == "pass" or expect == "fail", "unknown expectation: "..line:match("^[^:]+"));

				local valid = utf8.valid(data);
				assert.is.equal(valid, utf8.valid(data.." "));
				assert.is.equal(valid, expect == "pass", line);
			end

		end);
	end);
end);
