local ibh = require"util.indexedbheap";

local function verify_heap_property(priorities)
	for k in ipairs(priorities) do
		local parent = priorities[k];
		local childA = priorities[2*k];
		local childB = priorities[2*k+1];
		-- print("-", parent, childA, childB)
		assert(childA == nil or childA > parent, "heap property violated");
		assert(childB == nil or childB > parent, "heap property violated");
	end
end

local h
setup(function ()
	h = ibh.create();
end)
describe("util.indexedbheap", function ()
	it("item can be moved from end to top", function ()
		verify_heap_property(h);
		h:insert("a", 1);
		verify_heap_property(h);
		h:insert("b", 2);
		verify_heap_property(h);
		h:insert("c", 3);
		verify_heap_property(h);
		local id = h:insert("*", 10);
		verify_heap_property(h);
		h:reprioritize(id, 0);
		verify_heap_property(h);
		assert.same({ 0, "*", id }, { h:pop() });
	end)
end);
