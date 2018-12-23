local u_table = require "util.table";
describe("util.table", function ()
	describe("create()", function ()
		it("works", function ()
			-- Can't test the allocated sizes of the table, so what you gonna do?
			assert.is.table(u_table.create(1,1));
		end);
	end);

	describe("pack()", function ()
		it("works", function ()
			assert.same({ "lorem", "ipsum", "dolor", "sit", "amet", n = 5 }, u_table.pack("lorem", "ipsum", "dolor", "sit", "amet"));
		end);
	end);
end);


