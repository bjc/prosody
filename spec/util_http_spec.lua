
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

		it("should decode both lower and uppercase", function ()
			assert.are.equal("This & that = {something}.", http.urldecode("This%20%26%20that%20%3D%20%7Bsomething%7D%2E"), "Important URL chars escaped");
		end);

	end);

	describe("#formencode()", function()
		it("should encode basic data", function()
			assert.are.equal(http.formencode({ { name = "one", value = "1"}, { name = "two", value = "2" } }), "one=1&two=2", "Form encoded");
		end);

		it("should encode special characters with escaping", function()
			-- luacheck: ignore 631
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

	describe("normalize_path", function ()
		it("root path is always '/'", function ()
			assert.equal("/", http.normalize_path("/"));
			assert.equal("/", http.normalize_path(""));
			assert.equal("/", http.normalize_path("/", true));
			assert.equal("/", http.normalize_path("", true));
		end);

		it("works", function ()
			assert.equal("/foo", http.normalize_path("foo"));
			assert.equal("/foo", http.normalize_path("/foo"));
			assert.equal("/foo", http.normalize_path("foo/"));
			assert.equal("/foo", http.normalize_path("/foo/"));
		end);

		it("is_dir works", function ()
			assert.equal("/foo/", http.normalize_path("foo", true));
			assert.equal("/foo/", http.normalize_path("/foo", true));
			assert.equal("/foo/", http.normalize_path("foo/", true));
			assert.equal("/foo/", http.normalize_path("/foo/", true));
		end);
	end);

	describe("contains_token", function ()
		it("is present in field", function ()
			assert.is_true(http.contains_token("foo", "foo"));
			assert.is_true(http.contains_token("foo, bar", "foo"));
			assert.is_true(http.contains_token("foo,bar", "foo"));
			assert.is_true(http.contains_token("bar,  foo,baz", "foo"));
		end);

		it("is absent from field", function ()
			assert.is_false(http.contains_token("bar", "foo"));
			assert.is_false(http.contains_token("fooo", "foo"));
			assert.is_false(http.contains_token("foo o,bar", "foo"));
		end);

		it("is weird", function ()
			assert.is_(http.contains_token("fo o", "foo"));
		end);
	end);

do
	describe("parse_forwarded", function()
		it("works", function()
			assert.same({ { ["for"] = "[2001:db8:cafe::17]:4711" } }, http.parse_forwarded('For="[2001:db8:cafe::17]:4711"'), "case insensitive");

			assert.same({ { ["for"] = "192.0.2.60"; proto = "http"; by = "203.0.113.43" } }, http.parse_forwarded('for=192.0.2.60;proto=http;by=203.0.113.43'),
				"separated by semicolon");

			assert.same({ { ["for"] = "192.0.2.43" }; { ["for"] = "198.51.100.17" } }, http.parse_forwarded('for=192.0.2.43, for=198.51.100.17'),
				"Values from multiple proxy servers can be appended using a comma");

		end)
		it("rejects quoted quotes", function ()
			assert.falsy(http.parse_forwarded('foo="bar\"bar'), "quoted quotes");
		end)
		pending("deals with quoted quotes", function ()
			assert.same({ { foo = 'bar"baz' } }, http.parse_forwarded('foo="bar\"bar'), "quoted quotes");
		end)
	end)
end
end);
