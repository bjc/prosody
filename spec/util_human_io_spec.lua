describe("util.human.io", function ()
	local human_io
	setup(function ()
		human_io = require "util.human.io";
	end);
	describe("table", function ()

		it("alignment works", function ()
			local row = human_io.table({
					{
						width = 3,
						align = "right"
					},
					{
						width = 3,
					},
				});

			assert.equal("  1 | .  ", row({ 1, "." }));
			assert.equal(" 10 | .. ", row({ 10, ".." }));
			assert.equal("100 | ...", row({ 100, "..." }));
			assert.equal("10… | ..…", row({ 1000, "...." }));

		end);
	end);

	describe("ellipsis", function()
		it("works", function()
			assert.equal("…", human_io.ellipsis("abc", 1));
			assert.equal("a…", human_io.ellipsis("abc", 2));
			assert.equal("abc", human_io.ellipsis("abc", 3));

			assert.equal("…", human_io.ellipsis("räksmörgås", 1));
			assert.equal("r…", human_io.ellipsis("räksmörgås", 2));
			assert.equal("rä…", human_io.ellipsis("räksmörgås", 3));
			assert.equal("räk…", human_io.ellipsis("räksmörgås", 4));
			assert.equal("räks…", human_io.ellipsis("räksmörgås", 5));
			assert.equal("räksm…", human_io.ellipsis("räksmörgås", 6));
			assert.equal("räksmö…", human_io.ellipsis("räksmörgås", 7));
			assert.equal("räksmör…", human_io.ellipsis("räksmörgås", 8));
			assert.equal("räksmörg…", human_io.ellipsis("räksmörgås", 9));
			assert.equal("räksmörgås", human_io.ellipsis("räksmörgås", 10));
		end);
	end);

	describe("parse_duration", function ()
		local function test(expected, duration)
			return assert.equal(expected, human_io.parse_duration(duration), ("%q -> %d"):format(duration, expected));
		end
		local function should_fail(duration)
			assert.is_nil(human_io.parse_duration(duration), "invalid duration should fail: %q");
		end
		it("works", function ()
			test(1, "1s");
			test(60, "1min");
			test(60, "1 min");
			test(60, "1 minute");
			test(120, "2min");
			test(7200, "2h");
			test(7200, "2 hours");
			test(86400, "1d");
			test(604800, "1w");
			test(604800, "1week");
			test(1814400, "3 weeks");
			test(2678400, "1month");
			test(2678400, "1 month");
			test(31536000, "365 days");
			test(31556952, "1 year");

			should_fail("two weeks");
			should_fail("1m");
			should_fail("1mi");
			should_fail("1mo");
		end);
	end);

	describe("parse_duration_lax", function ()
		local function test(expected, duration)
			return assert.equal(expected, human_io.parse_duration_lax(duration), ("%q -> %d"):format(duration, expected));
		end
		it("works", function ()
			test(1, "1s");
			test(60, "1mi");
			test(60, "1min");
			test(60, "1 min");
			test(60, "1 minute");
			test(120, "2min");
			test(7200, "2h");
			test(7200, "2 hours");
			test(86400, "1d");
			test(604800, "1w");
			test(604800, "1week");
			test(1814400, "3 weeks");
			test(2678400, "1m");
			test(2678400, "1mo");
			test(2678400, "1month");
			test(2678400, "1 month");
			test(31536000, "365 days");
			test(31556952, "1 year");
			return assert.is_nil(human_io.parse_duration_lax("two weeks"), "\"2 weeks\" -> nil");
		end);
	end);
end);



