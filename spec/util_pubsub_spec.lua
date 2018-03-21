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
		local service = pubsub.new({ broadcaster = broadcaster; });

		it("creates a node", function ()
			assert.truthy(service:create("node", true));
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
end);
