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

	describe("move()", function ()
		it("works", function ()
			local t1 = { "apple", "banana", "carrot" };
			local t2 = { "cat", "donkey", "elephant" };
			local t3 = {};
			u_table.move(t1, 1, 3, 1, t3);
			u_table.move(t2, 1, 3, 3, t3);
			assert.same({ "apple", "banana", "cat", "donkey", "elephant" }, t3);
		end);
	end);
end);


