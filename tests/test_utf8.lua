package.cpath = "../?.so"
package.path = "../?.lua";

function valid()
	local encodings = require "util.encodings";
	local utf8 = assert(encodings.utf8, "no encodings.utf8 module");
	
	for line in io.lines("utf8_sequences.txt") do
		local data = line:match(":%s*([^#]+)"):gsub("%s+", ""):gsub("..", function (c) return string.char(tonumber(c, 16)); end)
		local expect = line:match("(%S+):");
		if expect ~= "pass" and expect ~= "fail" then
			error("unknown expectation: "..line:match("^[^:]+"));
		end
		local valid = utf8.valid(data);
		assert_equal(valid, utf8.valid(data.." "));
		assert_equal(valid, expect == "pass", line);
	end
end
