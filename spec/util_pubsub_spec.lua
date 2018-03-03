local pubsub = require "util.pubsub";
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
end);
