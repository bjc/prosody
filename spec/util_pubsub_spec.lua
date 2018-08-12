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

	describe("access model", function ()
		describe("open", function ()
			local service;
			before_each(function ()
				service = pubsub.new();
				-- Do not supply any config, 'open' should be default
				service:create("test", true);
			end);
			it("should be the default", function ()
				local ok, config = service:get_node_config("test", true);
				assert.equal("open", config.access_model);
			end);
			it("should allow anyone to subscribe", function ()
				local ok = service:add_subscription("test", "stranger", "stranger");
				assert.is_true(ok);
			end);
			it("should still reject outcast-affiliated entities", function ()
				assert(service:set_affiliation("test", true, "enemy", "outcast"));
				local ok, err = service:add_subscription("test", "enemy", "enemy");
				assert.is_falsy(ok);
				assert.equal("forbidden", err);
			end);
		end);
		describe("whitelist", function ()
			local service;
			before_each(function ()
				service = assert(pubsub.new());
				assert.is_true(service:create("test", true, { access_model = "whitelist" }));
			end);
			it("should be present in the configuration", function ()
				local ok, config = service:get_node_config("test", true);
				assert.equal("whitelist", config.access_model);
			end);
			it("should not allow anyone to subscribe", function ()
				local ok, err = service:add_subscription("test", "stranger", "stranger");
				assert.is_false(ok);
				assert.equals("forbidden", err);
			end);
		end);
	end);

	describe("publish model", function ()
		describe("publishers", function ()
			local service;
			before_each(function ()
				service = pubsub.new();
				-- Do not supply any config, 'publishers' should be default
				service:create("test", true);
			end);
			it("should be the default", function ()
				local ok, config = service:get_node_config("test", true);
				assert.equal("publishers", config.publish_model);
			end);
			it("should not allow anyone to publish", function ()
				assert.is_true(service:add_subscription("test", "stranger", "stranger"));
				local ok, err = service:publish("test", "stranger", "item1", "foo");
				assert.is_falsy(ok);
				assert.equals("forbidden", err);
			end);
			it("should allow publishers to publish", function ()
				assert(service:set_affiliation("test", true, "mypublisher", "publisher"));
				local ok, err = service:publish("test", "mypublisher", "item1", "foo");
				assert.is_true(ok);
			end);
			it("should allow owners to publish", function ()
				assert(service:set_affiliation("test", true, "myowner", "owner"));
				local ok = service:publish("test", "myowner", "item1", "foo");
				assert.is_true(ok);
			end);
		end);
		describe("open", function ()
			local service;
			before_each(function ()
				service = pubsub.new();
				service:create("test", true, { publish_model = "open" });
			end);
			it("should allow anyone to publish", function ()
				local ok = service:publish("test", "stranger", "item1", "foo");
				assert.is_true(ok);
			end);
		end);
		describe("subscribers", function ()
			local service;
			before_each(function ()
				service = pubsub.new();
				service:create("test", true, { publish_model = "subscribers" });
			end);
			it("should not allow non-subscribers to publish", function ()
				local ok, err = service:publish("test", "stranger", "item1", "foo");
				assert.is_falsy(ok);
				assert.equals("forbidden", err);
			end);
			it("should allow subscribers to publish without an affiliation", function ()
				assert.is_true(service:add_subscription("test", "stranger", "stranger"));
				local ok  = service:publish("test", "stranger", "item1", "foo");
				assert.is_true(ok);
			end);
			it("should allow publishers to publish without a subscription", function ()
				assert(service:set_affiliation("test", true, "mypublisher", "publisher"));
				local ok, err = service:publish("test", "mypublisher", "item1", "foo");
				assert.is_true(ok);
			end);
			it("should allow owners to publish without a subscription", function ()
				assert(service:set_affiliation("test", true, "myowner", "owner"));
				local ok = service:publish("test", "myowner", "item1", "foo");
				assert.is_true(ok);
			end);
		end);
	end);
end);
