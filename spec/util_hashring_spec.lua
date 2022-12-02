local hashring = require "util.hashring";

describe("util.hashring", function ()
	randomize(false);

	local sha256 = require "util.hashes".sha256;

	local ring = hashring.new(128, sha256);

	it("should fail to get a node that does not exist", function ()
		assert.is_nil(ring:get_node("foo"))
	end);

	it("should support adding nodes", function ()
		ring:add_node("node1");
	end);

	it("should return a single node for all keys if only one node exists", function ()
		for i = 1, 100 do
			assert.is_equal("node1", ring:get_node(tostring(i)))
		end
	end);

	it("should support adding a second node", function ()
		ring:add_node("node2");
	end);

	it("should fail to remove a non-existent node", function ()
		assert.is_falsy(ring:remove_node("node3"));
	end);

	it("should succeed to remove a node", function ()
		assert.is_truthy(ring:remove_node("node1"));
	end);

	it("should return the only node for all keys", function ()
		for i = 1, 100 do
			assert.is_equal("node2", ring:get_node(tostring(i)))
		end
	end);

	it("should support adding multiple nodes", function ()
		ring:add_nodes({ "node1", "node3", "node4", "node5" });
	end);

	it("should disrupt a minimal number of keys on node removal", function ()
		local orig_ring = ring:clone();
		local node_tallies = {};

		local n = 1000;

		for i = 1, n do
			local key = tostring(i);
			local node = ring:get_node(key);
			node_tallies[node] = (node_tallies[node] or 0) + 1;
		end

		--[[
		for node, key_count in pairs(node_tallies) do
			print(node, key_count, ("%.2f%%"):format((key_count/n)*100));
		end
		]]

		ring:remove_node("node5");

		local disrupted_keys = 0;
		for i = 1, n do
			local key = tostring(i);
			if orig_ring:get_node(key) ~= ring:get_node(key) then
				disrupted_keys = disrupted_keys + 1;
			end
		end
		assert.is_equal(node_tallies["node5"], disrupted_keys);
	end);

	it("should support removing multiple nodes", function ()
		ring:remove_nodes({"node2", "node3", "node4", "node5"});
	end);

	it("should return a single node for all keys if only one node remains", function ()
		for i = 1, 100 do
			assert.is_equal("node1", ring:get_node(tostring(i)))
		end
	end);

	it("should support values associated with nodes", function ()
		local r = hashring.new(128, sha256);
		r:add_node("node1", { a = 1 });
		local node, value = r:get_node("foo");
		assert.is_equal("node1", node);
		assert.same({ a = 1 }, value);
	end);
end);
