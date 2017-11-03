
local encodings = require "util.encodings";
local utf8 = assert(encodings.utf8, "no encodings.utf8 module");

describe("util.encodings", function ()
	describe("#encode()", function()
		it("should work", function ()
			assert.is.equal(encodings.base64.encode(""), "");
			assert.is.equal(encodings.base64.encode('coucou'), "Y291Y291");
			assert.is.equal(encodings.base64.encode("\0\0\0"), "AAAA");
			assert.is.equal(encodings.base64.encode("\255\255\255"), "////");
		end);
	end);
	describe("#decode()", function()
		it("should work", function ()
			assert.is.equal(encodings.base64.decode(""), "");
			assert.is.equal(encodings.base64.decode("="), "");
			assert.is.equal(encodings.base64.decode('Y291Y291'), "coucou");
			assert.is.equal(encodings.base64.decode("AAAA"), "\0\0\0");
			assert.is.equal(encodings.base64.decode("////"), "\255\255\255");
		end);
	end);
end);
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
