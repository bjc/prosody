local util_datetime = require "util.datetime";

describe("util.datetime", function ()
	it("should have been loaded", function ()
		assert.is_table(util_datetime);
	end);
	describe("#date", function ()
		local date = util_datetime.date;
		it("should exist", function ()
			assert.is_function(date);
		end);
		it("should return a string", function ()
			assert.is_string(date());
		end);
		it("should look like a date", function ()
			assert.truthy(string.find(date(), "^%d%d%d%d%-%d%d%-%d%d$"));
		end);
		it("should work", function ()
			assert.equals("2006-01-02", date(1136239445));
		end);
	end);
	describe("#time", function ()
		local time = util_datetime.time;
		it("should exist", function ()
			assert.is_function(time);
		end);
		it("should return a string", function ()
			assert.is_string(time());
		end);
		it("should look like a timestamp", function ()
			-- Note: Sub-second precision and timezones are ignored
			assert.truthy(string.find(time(), "^%d%d:%d%d:%d%d"));
		end);
		it("should work", function ()
			assert.equals("22:04:05", time(1136239445));
		end);
	end);
	describe("#datetime", function ()
		local datetime = util_datetime.datetime;
		it("should exist", function ()
			assert.is_function(datetime);
		end);
		it("should return a string", function ()
			assert.is_string(datetime());
		end);
		it("should look like a timestamp", function ()
			-- Note: Sub-second precision and timezones are ignored
			assert.truthy(string.find(datetime(), "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d"));
		end);
		it("should work", function ()
			assert.equals("2006-01-02T22:04:05Z", datetime(1136239445));
		end);
	end);
	describe("#legacy", function ()
		local legacy = util_datetime.legacy;
		it("should exist", function ()
			assert.is_function(legacy);
		end);
	end);
	describe("#parse", function ()
		local parse = util_datetime.parse;
		it("should exist", function ()
			assert.is_function(parse);
		end);
		it("should work", function ()
			-- Timestamp used by Go
			assert.equals(1511114293, parse("2017-11-19T17:58:13Z"));
			assert.equals(1511114330, parse("2017-11-19T18:58:50+0100"));
			assert.equals(1136239445, parse("2006-01-02T15:04:05-0700"));
		end);
		it("should handle timezones", function ()
			-- https://xmpp.org/extensions/xep-0082.html#example-2 and 3
			assert.equals(parse("1969-07-21T02:56:15Z"), parse("1969-07-20T21:56:15-05:00"));
		end);
	end);
end);
