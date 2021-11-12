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
end);



