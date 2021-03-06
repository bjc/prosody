local xml
local map

setup(function()
	xml = require "util.xml";
	map = require "util.datamapper";
end);

describe("util.datampper", function()

	local s, x, d
	setup(function()

		local function attr() return {type = "string"; xml = {attribute = true}} end
		s = {
			type = "object";
			xml = {name = "message"; namespace = "jabber:client"};
			properties = {
				to = attr();
				from = attr();
				type = attr();
				id = attr();
				body = "string";
				lang = {type = "string"; xml = {attribute = true; prefix = "xml"}};
				delay = {
					type = "object";
					xml = {namespace = "urn:xmpp:delay"; name = "delay"};
					properties = {stamp = attr(); from = attr(); reason = {type = "string"; xml = {text = true}}};
				};
			};
		};

		x = xml.parse [[
			<message xmlns="jabber:client" xml:lang="en" to="a@test" from="b@test" type="chat" id="1">
			<body>Hello</body>
			<delay xmlns='urn:xmpp:delay' from='test' stamp='2021-03-07T15:59:08+00:00'>Becasue</delay>
			</message>
		]];

		d = {
			to = "a@test";
			from = "b@test";
			type = "chat";
			id = "1";
			lang = "en";
			body = "Hello";
			delay = {from = "test"; stamp = "2021-03-07T15:59:08+00:00"; reason = "Becasue"};
		};
	end);

	describe("parse", function()
		it("works", function()
			assert.same(d, map.parse(s, x));
		end);
	end);

	describe("unparse", function()
		it("works", function()
			local u = map.unparse(s, d);
			assert.equal("message", u.name);
			assert.same(x.attr, u.attr);
			assert.equal(#x.tags, #u.tags)
			assert.equal(x:get_child_text("body"), u:get_child_text("body"));
			assert.equal(x:get_child_text("delay", "urn:xmpp:delay"), u:get_child_text("delay", "urn:xmpp:delay"));
			assert.same(x:get_child("delay", "urn:xmpp:delay").attr, u:get_child("delay", "urn:xmpp:delay").attr);
		end);
	end);
end)
