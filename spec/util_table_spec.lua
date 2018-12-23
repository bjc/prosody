local u_table = require "util.table";
describe("util.table", function ()
	describe("pack()", function ()
		it("works", function ()
			assert.same({ "lorem", "ipsum", "dolor", "sit", "amet", n = 5 }, u_table.pack("lorem", "ipsum", "dolor", "sit", "amet"));
		end);
	end);
end);


