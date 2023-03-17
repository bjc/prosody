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
		it("supports overlapping regions", function ()
			do
				local t1 = { "apple", "banana", "carrot", "date", "endive", "fig", "grapefruit" };
				u_table.move(t1, 1, 3, 3);
				assert.same({ "apple", "banana", "apple", "banana", "carrot", "fig", "grapefruit" }, t1);
			end

			do
				local t1 = { "apple", "banana", "carrot", "date", "endive", "fig", "grapefruit" };
				u_table.move(t1, 1, 3, 2);
				assert.same({ "apple", "apple", "banana", "carrot", "endive", "fig", "grapefruit" }, t1);
			end

			do
				local t1 = { "apple", "banana", "carrot", "date", "endive", "fig", "grapefruit" };
				u_table.move(t1, 3, 5, 2);
				assert.same({ "apple", "carrot", "date", "endive", "endive", "fig", "grapefruit" }, t1);
			end

			do
				local t1 = { "apple", "banana", "carrot", "date", "endive", "fig", "grapefruit" };
				u_table.move(t1, 3, 5, 6);
				assert.same({ "apple", "banana", "carrot", "date", "endive", "carrot", "date", "endive" }, t1);
			end

			do
				local t1 = { "apple", "banana", "carrot", "date", "endive", "fig", "grapefruit" };
				u_table.move(t1, 3, 1, 3);
				assert.same({ "apple", "banana", "carrot", "date", "endive", "fig", "grapefruit" }, t1);
			end
		end);
	end);
end);


