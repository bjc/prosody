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

		it("all fields works", function()
			local test = assert(xml.parse(strip([[
				<set xmlns='http://jabber.org/protocol/rsm'>
					<after>a</after>
					<before>b</before>
					<count>10</count>
					<first index='1'>f</first>
					<index>5</index>
					<last>z</last>
					<max>100</max>
				</set>
				]])));
			assert.same({
				after = "a";
				before = "b";
				count = 10;
				first = {index = 1; "f"};
				index = 5;
				last = "z";
				max = 100;
			}, rsm.parse(test));
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


		it("all fields works", function ()
			local res = rsm.generate({
					after = "a";
					before = "b";
					count = 10;
					first = {index = 1; "f"};
					index = 5;
					last = "z";
					max = 100;
				});
			assert.equal("a", res:get_child_text("after"));
			assert.equal("b", res:get_child_text("before"));
			assert.equal("10", res:get_child_text("count"));
			assert.equal("f", res:get_child_text("first"));
			assert.equal("1", res:get_child("first").attr.index);
			assert.equal("5", res:get_child_text("index"));
			assert.equal("z", res:get_child_text("last"));
			assert.equal("100", res:get_child_text("max"));
		end);
	end);

end);

