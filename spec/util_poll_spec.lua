describe("util.poll", function()
	local poll;
	setup(function()
		poll = require "util.poll";
	end);
	it("loads", function()
		assert.is_table(poll);
		assert.is_function(poll.new);
		assert.is_string(poll.api);
	end);
	describe("new", function()
		local p;
		setup(function()
			p = poll.new();
		end)
		it("times out", function ()
			local fd, err = p:wait(0);
			assert.falsy(fd);
			assert.equal("timeout", err);
		end);
		it("works", function()
			-- stdout should be writable, right?
			assert.truthy(p:add(1, false, true));
			local fd, r, w = p:wait(1);
			assert.is_number(fd);
			assert.is_boolean(r);
			assert.is_boolean(w);
			assert.equal(1, fd);
			assert.falsy(r);
			assert.truthy(w);
			assert.truthy(p:del(1));
		end);
	end)
end);

