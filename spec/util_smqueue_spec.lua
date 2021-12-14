describe("util.smqueue", function()

	local smqueue
	setup(function() smqueue = require "util.smqueue"; end)

	describe("#new()", function()
		it("should work", function()
			local q = smqueue.new(10);
			assert.truthy(q);
		end)
	end)

	describe("#push()", function()
		it("should allow pushing many items", function()
			local q = smqueue.new(10);
			for i = 1, 20 do q:push(i); end
			assert.equal(20, q:count_unacked());
		end)
	end)

	describe("#resumable()", function()
		it("returns true while the queue is small", function()
			local q = smqueue.new(10);
			for i = 1, 10 do q:push(i); end
			assert.truthy(q:resumable());
			q:push(11);
			assert.falsy(q:resumable());
		end)
	end)

	describe("#ack", function()
		it("allows removing items", function()
			local q = smqueue.new(10);
			for i = 1, 10 do q:push(i); end
			assert.same({ 1; 2; 3 }, q:ack(3));
			assert.same({ 4; 5; 6 }, q:ack(6));
			assert.falsy(q:ack(3), "can't go backwards")
			assert.falsy(q:ack(100), "can't ack too many")
			for i = 11, 20 do q:push(i); end
			assert.same({ 11; 12 }, q:ack(12), "items are dropped");
		end)
	end)

	describe("#resume", function()
		it("iterates over current items", function()
			local q = smqueue.new(10);
			for i = 1, 12 do q:push(i); end
			assert.same({ 3; 4; 5; 6 }, q:ack(6));
			assert.truthy(q:resumable());
			local resume = {}
			for _, i in q:resume() do resume[i] = true end
			assert.same({ [7] = true; [8] = true; [9] = true; [10] = true; [11] = true; [12] = true }, resume);
		end)
	end)
end);
