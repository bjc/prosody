local format = require "util.format".format;

describe("util.format", function()
	describe("#format()", function()
		it("should work", function()
			assert.equal("hello", format("%s", "hello"));
			assert.equal("(nil)", format("%s"));
			assert.equal("(nil)", format("%d"));
			assert.equal("(nil)", format("%q"));
			assert.equal(" [(nil)]", format("", nil));
			assert.equal("true", format("%s", true));
			assert.equal("[true]", format("%d", true));
			assert.equal("% [true]", format("%%", true));
			assert.equal("{ }", format("%q", { }));
			assert.equal("[1.5]", format("%d", 1.5));
			assert.equal("[7.3786976294838e+19]", format("%d", 73786976294838206464));
		end);

		it("escapes ascii control stuff", function ()
			assert.equal("␁", format("%s", "\1"));
			assert.equal("[␁]", format("%d", "\1"));
		end);

		it("escapes invalid UTF-8", function ()
			assert.equal("\"Hello w\\195rld\"", format("%s", "Hello w\195rld"));
		end);

	end);
end);
