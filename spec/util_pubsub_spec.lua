local pubsub;
setup(function ()
	pubsub = require "util.pubsub";
end);

describe("util.pubsub", function ()
	describe("simple node creation and deletion", function ()
		-- Roughly a port of scansion/scripts/pubsub_createdelete.scs
		local service = pubsub.new();

		describe("#create", function ()
			it("creates a new node", function ()
				assert.truthy(service:create("princely_musings", true));
			end);

			it("fails to create the same node again", function ()
				assert.falsy(service:create("princely_musings", true));
			end);
		end);

		describe("#delete", function ()
			it("deletes the node", function ()
				assert.truthy(service:delete("princely_musings", true));
			end);

			it("can't delete an already deleted node", function ()
				assert.falsy(service:delete("princely_musings", true));
			end);
		end);
	end);

	describe("simple publishing", function ()
		local broadcaster = spy.new(function () end);
		local service = pubsub.new({
			broadcaster = broadcaster;
		});

		it("creates a node", function ()
			assert.truthy(service:create("node", true));
		end);

		it("lets someone subscribe", function ()
			assert.truthy(service:add_subscription("node", true, "someone"));
		end);

		it("publishes an item", function ()
			assert.truthy(service:publish("node", true, "1", "item 1"));
		end);

		it("called the broadcaster", function ()
			assert.spy(broadcaster).was_called();
		end);

		it("should return one item", function ()
			local ok, ret = service:get_items("node", true);
			assert.truthy(ok);
			assert.same({ "1", ["1"] = "item 1" }, ret);
		end);

	end);

	describe("#issue1082", function ()
		local service = pubsub.new();

		it("creates a node with max_items = 1", function ()
			assert.truthy(service:create("node", true, { max_items = 1 }));
		end);

		it("changes max_items to 2", function ()
			assert.truthy(service:set_node_config("node", true, { max_items = 2 }));
		end);

		it("publishes one item", function ()
			assert.truthy(service:publish("node", true, "1", "item 1"));
		end);

		it("should return one item", function ()
			local ok, ret = service:get_items("node", true);
			assert.truthy(ok);
			assert.same({ "1", ["1"] = "item 1" }, ret);
		end);

		it("publishes another item", function ()
			assert.truthy(service:publish("node", true, "2", "item 2"));
		end);

		it("should return two items", function ()
			local ok, ret = service:get_items("node", true);
			assert.truthy(ok);
			assert.same({
				"2",
				"1",
				["1"] = "item 1",
				["2"] = "item 2",
			}, ret);
		end);

		it("publishes yet another item", function ()
			assert.truthy(service:publish("node", true, "3", "item 3"));
		end);

		it("should still return only two items", function ()
			local ok, ret = service:get_items("node", true);
			assert.truthy(ok);
			assert.same({
				"3",
				"2",
				["2"] = "item 2",
				["3"] = "item 3",
			}, ret);
		end);

	end);
end);
