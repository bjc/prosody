local st
local xml
local map

setup(function()
	st = require "util.stanza";
	xml = require "util.xml";
	map = require "util.datamapper";
end);

describe("util.datamapper", function()

	local s, x, d
	local disco, disco_info, disco_schema
	setup(function()

		-- a convenience function for simple attributes, there's a few of them
		local function attr() return {["$ref"]="#/$defs/attr"} end
		s = {
			["$defs"] = { attr = { type = "string"; xml = { attribute = true } } };
			type = "object";
			xml = {name = "message"; namespace = "jabber:client"};
			properties = {
				to = attr();
				from = attr();
				type = attr();
				id = attr();
				body = true; -- should be assumed to be a string
				lang = {type = "string"; xml = {attribute = true; prefix = "xml"}};
				delay = {
					type = "object";
					xml = {namespace = "urn:xmpp:delay"; name = "delay"};
					properties = {stamp = attr(); from = attr(); reason = {type = "string"; xml = {text = true}}};
				};
				state = {
					type = "string";
					enum = {
						"active",
						"inactive",
						"gone",
						"composing",
						"paused",
					};
					xml = {x_name_is_value = true; namespace = "http://jabber.org/protocol/chatstates"};
				};
				fallback = {
					type = "boolean";
					xml = {x_name_is_value = true; name = "fallback"; namespace = "urn:xmpp:fallback:0"};
				};
				origin_id = {
					type = "string";
					xml = {name = "origin-id"; namespace = "urn:xmpp:sid:0"; x_single_attribute = "id"};
				};
				react = {
					type = "object";
					xml = {namespace = "urn:xmpp:reactions:0"; name = "reactions"};
					properties = {
						to = {type = "string"; xml = {attribute = true; name = "id"}};
						-- should be assumed to be array since it has 'items'
						reactions = { items = { xml = { name = "reaction" } } };
					};
				};
				stanza_ids = {
					type = "array";
					items = {
						xml = {name = "stanza-id"; namespace = "urn:xmpp:sid:0"};
						type = "object";
						properties = {
							id = attr();
							by = attr();
						};
					};
				};
			};
		};

		x = xml.parse [[
				<message xmlns="jabber:client" xml:lang="en" to="a@test" from="b@test" type="chat" id="1">
				<body>Hello</body>
				<delay xmlns='urn:xmpp:delay' from='test' stamp='2021-03-07T15:59:08+00:00'>Because</delay>
				<UNRELATED xmlns='http://jabber.org/protocol/chatstates'/>
				<active xmlns='http://jabber.org/protocol/chatstates'/>
				<fallback xmlns='urn:xmpp:fallback:0'/>
				<origin-id xmlns='urn:xmpp:sid:0' id='qgkmMdPB'/>
				<stanza-id xmlns='urn:xmpp:sid:0' id='abc1' by='muc'/>
				<stanza-id xmlns='urn:xmpp:sid:0' id='xyz2' by='host'/>
				<reactions id='744f6e18-a57a-11e9-a656-4889e7820c76' xmlns='urn:xmpp:reactions:0'>
					<reaction>👋</reaction>
					<reaction>🐢</reaction>
				</reactions>
				</message>
				]];

		d = {
			to = "a@test";
			from = "b@test";
			type = "chat";
			id = "1";
			lang = "en";
			body = "Hello";
			delay = {from = "test"; stamp = "2021-03-07T15:59:08+00:00"; reason = "Because"};
			state = "active";
			fallback = true;
			origin_id = "qgkmMdPB";
			stanza_ids = {{id = "abc1"; by = "muc"}; {id = "xyz2"; by = "host"}};
			react = {
				to = "744f6e18-a57a-11e9-a656-4889e7820c76";
				reactions = {
					"👋",
					"🐢",
				};
			};
		};

		disco_schema = {
			["$defs"] = { attr = { type = "string"; xml = { attribute = true } } };
			type = "object";
			xml = {
				name = "iq";
				namespace = "jabber:client"
			};
			properties = {
				to = attr();
				from = attr();
				type = attr();
				id = attr();
				disco = {
					type = "object";
					xml = {
						name = "query";
						namespace	= "http://jabber.org/protocol/disco#info"
					};
					properties = {
						features = {
							type = "array";
							items = {
								type = "string";
								xml = {
									name = "feature";
									x_single_attribute = "var";
								};
							};
						};
					};
				};
			};
		};

		disco_info = xml.parse[[
		<iq type="result" id="disco1" from="example.com">
			<query xmlns="http://jabber.org/protocol/disco#info">
				<feature var="urn:example:feature:1">wrong</feature>
				<feature var="urn:example:feature:2"/>
				<feature var="urn:example:feature:3"/>
				<unrelated var="urn:example:feature:not"/>
			</query>
		</iq>
		]];

		disco = {
			type="result";
			id="disco1";
			from="example.com";
			disco = {
				features = {
					"urn:example:feature:1";
					"urn:example:feature:2";
					"urn:example:feature:3";
				};
			};
		};
	end);

	describe("parse", function()
		it("works", function()
			assert.same(d, map.parse(s, x));
		end);

		it("handles arrays", function ()
			assert.same(disco, map.parse(disco_schema, disco_info));
		end);

		it("deals with locally built stanzas", function()
			-- FIXME this could also be argued to be a util.stanza problem
			local ver_schema = {
				type = "object";
				xml = {name = "iq"};
				properties = {
					type = {type = "string"; xml = {attribute = true}};
					id = {type = "string"; xml = {attribute = true}};
					version = {
						type = "object";
						xml = {name = "query"; namespace = "jabber:iq:version"};
						-- properties should be assumed to be strings
						properties = {name = true; version = {}; os = {}};
					};
				};
			};
			local ver_st = st.iq({type = "result"; id = "v1"})
				:query("jabber:iq:version")
					:text_tag("name", "Prosody")
					:text_tag("version", "trunk")
					:text_tag("os", "Lua 5.3")
				:reset();

			local data = {type = "result"; id = "v1"; version = {name = "Prosody"; version = "trunk"; os = "Lua 5.3"}}
			assert.same(data, map.parse(ver_schema, ver_st));
		end);

	end);

	describe("unparse", function()
		it("works", function()
			local u = map.unparse(s, d);
			assert.equal("message", u.name);
			assert.same(x.attr, u.attr);
			assert.equal(x:get_child_text("body"), u:get_child_text("body"));
			assert.equal(x:get_child_text("delay", "urn:xmpp:delay"), u:get_child_text("delay", "urn:xmpp:delay"));
			assert.same(x:get_child("delay", "urn:xmpp:delay").attr, u:get_child("delay", "urn:xmpp:delay").attr);
			assert.same(x:get_child("origin-id", "urn:xmpp:sid:0").attr, u:get_child("origin-id", "urn:xmpp:sid:0").attr);
			assert.same(x:get_child("reactions", "urn:xmpp:reactions:0").attr, u:get_child("reactions", "urn:xmpp:reactions:0").attr);
			assert.same(2, #u:get_child("reactions", "urn:xmpp:reactions:0").tags);
			for _, tag in ipairs(x.tags) do
				if tag.name ~= "UNRELATED" then
					assert.truthy(u:get_child(tag.name, tag.attr.xmlns) or u:get_child(tag.name), tag:top_tag())
				end
			end
			assert.equal(#x.tags-1, #u.tags)

		end);

		it("handles arrays", function ()
			local u = map.unparse(disco_schema, disco);
			assert.equal("urn:example:feature:1", u:find("{http://jabber.org/protocol/disco#info}query/feature/@var"))
			local n = 0;
			for child in u:get_child("query", "http://jabber.org/protocol/disco#info"):childtags("feature") do
				n = n + 1;
				assert.equal(string.format("urn:example:feature:%d", n), child.attr.var);
			end
		end);

	end);
end)
