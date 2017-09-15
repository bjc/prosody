
local http = require "util.http";

describe("util.http", function()
	describe("#urlencode()", function()
		it("should not change normal characters", function()
			assert.are.equal(http.urlencode("helloworld123"), "helloworld123");
		end);

		it("should escape spaces", function()
			assert.are.equal(http.urlencode("hello world"), "hello%20world");
		end);

		it("should escape important URL characters", function()
			assert.are.equal(http.urlencode("This & that = something"), "This%20%26%20that%20%3d%20something");
		end);
	end);

	describe("#urldecode()", function()
		it("should not change normal characters", function()
			assert.are.equal("helloworld123", http.urldecode("helloworld123"), "Normal characters not escaped");
		end);

		it("should decode spaces", function()
			assert.are.equal("hello world", http.urldecode("hello%20world"), "Spaces escaped");
		end);

		it("should decode important URL characters", function()
			assert.are.equal("This & that = something", http.urldecode("This%20%26%20that%20%3d%20something"), "Important URL chars escaped");
		end);
	end);

	describe("#formencode()", function()
		it("should encode basic data", function()
			assert.are.equal(http.formencode({ { name = "one", value = "1"}, { name = "two", value = "2" } }), "one=1&two=2", "Form encoded");
		end);

		it("should encode special characters with escaping", function()
			assert.are.equal(http.formencode({ { name = "one two", value = "1"}, { name = "two one&", value = "2" } }), "one+two=1&two+one%26=2", "Form encoded");
		end);
	end);

	describe("#formdecode()", function()
		it("should decode basic data", function()
			local t = http.formdecode("one=1&two=2");
			assert.are.same(t, {
				{ name = "one", value = "1" };
				{ name = "two", value = "2" };
				one = "1";
				two = "2";
			});
		end);

		it("should decode special characters", function()
			local t = http.formdecode("one+two=1&two+one%26=2");
			assert.are.same(t, {
				{ name = "one two", value = "1" };
				{ name = "two one&", value = "2" };
				["one two"] = "1";
				["two one&"] = "2";
			});
		end);
	end);
end);
