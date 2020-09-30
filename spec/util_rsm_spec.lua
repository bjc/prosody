local rsm = require "util.rsm";
local xml = require "util.xml";

local function strip(s)
	return (s:gsub(">%s+<", "><"));
end

describe("util.rsm", function ()
	describe("parse", function ()
		it("works", function ()
			local test = xml.parse(strip([[
				<set xmlns='http://jabber.org/protocol/rsm'>
					<max>10</max>
				</set>
				]]));
			assert.same({ max = 10 }, rsm.parse(test));
		end);

		it("works", function ()
			local test = xml.parse(strip([[
				<set xmlns='http://jabber.org/protocol/rsm'>
					<first index='0'>saint@example.org</first>
					<last>peterpan@neverland.lit</last>
					<count>800</count>
				</set>
				]]));
			assert.same({ first = { index = 0, "saint@example.org" }, last = "peterpan@neverland.lit", count = 800 }, rsm.parse(test));
		end);

		it("works", function ()
			local test = xml.parse(strip([[
				<set xmlns='http://jabber.org/protocol/rsm'>
					<max>10</max>
					<before>peter@pixyland.org</before>
				</set>
				]]));
			assert.same({ max = 10, before = "peter@pixyland.org" }, rsm.parse(test));
		end);

	end);

	describe("generate", function ()
		it("works", function ()
			local test = xml.parse(strip([[
				<set xmlns='http://jabber.org/protocol/rsm'>
					<max>10</max>
				</set>
				]]));
			local res = rsm.generate({ max = 10 });
			assert.same(test:get_child_text("max"), res:get_child_text("max"));
		end);

		it("works", function ()
			local test = xml.parse(strip([[
				<set xmlns='http://jabber.org/protocol/rsm'>
					<first index='0'>saint@example.org</first>
					<last>peterpan@neverland.lit</last>
					<count>800</count>
				</set>
				]]));
			local res = rsm.generate({ first = { index = 0, "saint@example.org" }, last = "peterpan@neverland.lit", count = 800 });
			assert.same(test:get_child("first").attr.index, res:get_child("first").attr.index);
			assert.same(test:get_child_text("first"), res:get_child_text("first"));
			assert.same(test:get_child_text("last"), res:get_child_text("last"));
			assert.same(test:get_child_text("count"), res:get_child_text("count"));
		end);

		it("works", function ()
			local test = xml.parse(strip([[
			<set xmlns='http://jabber.org/protocol/rsm'>
				<max>10</max>
				<before>peter@pixyland.org</before>
			</set>
			]]));
			local res = rsm.generate({ max = 10, before = "peter@pixyland.org" });
			assert.same(test:get_child_text("max"), res:get_child_text("max"));
			assert.same(test:get_child_text("before"), res:get_child_text("before"));
		end);

		it("handles floats", function ()
			local r1 = rsm.generate({ max = 10.0, count = 100.0, first = { index = 1.0, "foo" } });
			assert.equal("10", r1:get_child_text("max"));
			assert.equal("100", r1:get_child_text("count"));
			assert.equal("1", r1:get_child("first").attr.index);
		end);

	end);
end);

