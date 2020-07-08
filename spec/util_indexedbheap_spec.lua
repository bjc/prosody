local ibh = require"util.indexedbheap";
local h
setup(function ()
	h = ibh.create();
end)
describe("util.indexedbheap", function ()
	pending("item can be moved from end to top", function ()
		h:insert("a", 1);
		h:insert("b", 2);
		h:insert("c", 3);
		local id = h:insert("*", 10);
		h:reprioritize(id, 0);
		assert.same({ 0, "*", id }, { h:pop() });
	end)
end);
