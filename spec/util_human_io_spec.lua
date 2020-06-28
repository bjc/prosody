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
end);



