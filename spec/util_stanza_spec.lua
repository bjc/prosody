
local st = require "util.stanza";
local errors = require "util.error";

describe("util.stanza", function()
	describe("#preserialize()", function()
		it("should work", function()
			local stanza = st.stanza("message", { type = "chat" }):text_tag("body", "Hello");
			local stanza2 = st.preserialize(stanza);
			assert.is_table(stanza2, "Preserialized stanza is a table");
			assert.is_nil(getmetatable(stanza2), "Preserialized stanza has no metatable");
			assert.is_string(stanza2.name, "Preserialized stanza has a name field");
			assert.equal(stanza.name, stanza2.name, "Preserialized stanza has same name as the input stanza");
			assert.same(stanza.attr, stanza2.attr, "Preserialized stanza same attr table as input stanza");
			assert.is_nil(stanza2.tags, "Preserialized stanza has no tag list");
			assert.is_nil(stanza2.last_add, "Preserialized stanza has no last_add marker");
			assert.is_table(stanza2[1], "Preserialized child element preserved");
			assert.equal("body", stanza2[1].name, "Preserialized child element name preserved");
		end);
	end);

	describe("#deserialize()", function()
		it("should work", function()
			local stanza = { name = "message", attr = { type = "chat" }, { name = "body", attr = { }, "Hello" } };
			local stanza2 = st.deserialize(st.preserialize(stanza));

			assert.is_table(stanza2, "Deserialized stanza is a table");
			assert.equal(st.stanza_mt, getmetatable(stanza2), "Deserialized stanza has stanza metatable");
			assert.is_string(stanza2.name, "Deserialized stanza has a name field");
			assert.equal(stanza.name, stanza2.name, "Deserialized stanza has same name as the input table");
			assert.same(stanza.attr, stanza2.attr, "Deserialized stanza same attr table as input table");
			assert.is_table(stanza2.tags, "Deserialized stanza has tag list");
			assert.is_table(stanza2[1], "Deserialized child element preserved");
			assert.equal("body", stanza2[1].name, "Deserialized child element name preserved");
		end);
	end);

	describe("#stanza()", function()
		it("should work", function()
			local s = st.stanza("foo", { xmlns = "myxmlns", a = "attr-a" });
			assert.are.equal(s.name, "foo");
			assert.are.equal(s.attr.xmlns, "myxmlns");
			assert.are.equal(s.attr.a, "attr-a");

			local s1 = st.stanza("s1");
			assert.are.equal(s1.name, "s1");
			assert.are.equal(s1.attr.xmlns, nil);
			assert.are.equal(#s1, 0);
			assert.are.equal(#s1.tags, 0);

			s1:tag("child1");
			assert.are.equal(#s1.tags, 1);
			assert.are.equal(s1.tags[1].name, "child1");

			s1:tag("grandchild1"):up();
			assert.are.equal(#s1.tags, 1);
			assert.are.equal(s1.tags[1].name, "child1");
			assert.are.equal(#s1.tags[1], 1);
			assert.are.equal(s1.tags[1][1].name, "grandchild1");

			s1:up():tag("child2");
			assert.are.equal(#s1.tags, 2, tostring(s1));
			assert.are.equal(s1.tags[1].name, "child1");
			assert.are.equal(s1.tags[2].name, "child2");
			assert.are.equal(#s1.tags[1], 1);
			assert.are.equal(s1.tags[1][1].name, "grandchild1");

			s1:up():text("Hello world");
			assert.are.equal(#s1.tags, 2);
			assert.are.equal(#s1, 3);
			assert.are.equal(s1.tags[1].name, "child1");
			assert.are.equal(s1.tags[2].name, "child2");
			assert.are.equal(#s1.tags[1], 1);
			assert.are.equal(s1.tags[1][1].name, "grandchild1");
		end);
		it("should work with unicode values", function ()
			local s = st.stanza("Объект", { xmlns = "myxmlns", ["Объект"] = "&" });
			assert.are.equal(s.name, "Объект");
			assert.are.equal(s.attr.xmlns, "myxmlns");
			assert.are.equal(s.attr["Объект"], "&");
		end);
		it("should allow :text() with nil and empty strings", function ()
			local s_control = st.stanza("foo");
			assert.same(st.stanza("foo"):text(), s_control);
			assert.same(st.stanza("foo"):text(nil), s_control);
			assert.same(st.stanza("foo"):text(""), s_control);
		end);
		it("validates names", function ()
			assert.has_error_match(function ()
				st.stanza("invalid\0name");
			end, "invalid tag name:")
			assert.has_error_match(function ()
				st.stanza("name", { ["foo\1\2\3bar"] = "baz" });
			end, "invalid attribute name: contains control characters")
			assert.has_error_match(function ()
				st.stanza("name", { ["foo"] = "baz\1\2\3\255moo" });
			end, "invalid attribute value: contains control characters")
		end)
		it("validates types", function ()
			assert.has_error_match(function ()
				st.stanza(1);
			end, "invalid tag name: expected string, got number")
			assert.has_error_match(function ()
				st.stanza("name", "string");
			end, "invalid attributes: expected table, got string")
			assert.has_error_match(function ()
				st.stanza("name",{1});
			end, "invalid attribute name: expected string, got number")
			assert.has_error_match(function ()
				st.stanza("name",{foo=1});
			end, "invalid attribute value: expected string, got number")
		end)
	end);

	describe("#message()", function()
		it("should work", function()
			local m = st.message();
			assert.are.equal(m.name, "message");
		end);
	end);

	describe("#iq()", function()
		it("should create an iq stanza", function()
			local i = st.iq({ type = "get", id = "foo" });
			assert.are.equal("iq", i.name);
			assert.are.equal("foo", i.attr.id);
			assert.are.equal("get", i.attr.type);
		end);

		it("should reject stanzas with no attributes", function ()
			assert.has.error_match(function ()
				st.iq();
			end, "attributes");
		end);


		it("should reject stanzas with no id", function ()
			assert.has.error_match(function ()
				st.iq({ type = "get" });
			end, "id attribute");
		end);

		it("should reject stanzas with no type", function ()
			assert.has.error_match(function ()
				st.iq({ id = "foo" });
			end, "type attribute");

		end);
	end);

	describe("#presence()", function ()
		it("should work", function()
			local p = st.presence();
			assert.are.equal(p.name, "presence");
		end);
	end);

	describe("#reply()", function()
		it("should work for <s>", function()
			-- Test stanza
			local s = st.stanza("s", { to = "touser", from = "fromuser", id = "123" })
				:tag("child1");
			-- Make reply stanza
			local r = st.reply(s);
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(#r.tags, 0, "A reply should not include children of the original stanza");
		end);

		it("should work for <iq get>", function()
			-- Test stanza
			local s = st.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "get" })
				:tag("child1");
			-- Make reply stanza
			local r = st.reply(s);
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(r.attr.type, "result");
			assert.are.equal(#r.tags, 0, "A reply should not include children of the original stanza");
		end);

		it("should work for <iq set>", function()
			-- Test stanza
			local s = st.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "set" })
				:tag("child1");
			-- Make reply stanza
			local r = st.reply(s);
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(r.attr.type, "result");
			assert.are.equal(#r.tags, 0, "A reply should not include children of the original stanza");
		end);

		it("should reject not-stanzas", function ()
			assert.has.error_match(function ()
				st.reply(not "a stanza");
			end, "expected stanza");
		end);

		it("should reject not-stanzas", function ()
			assert.has.error_match(function ()
				st.reply({name="x"});
			end, "expected stanza");
		end);

	end);

	describe("#error_reply()", function()
		it("should work for <s>", function()
			-- Test stanza
			local s = st.stanza("s", { to = "touser", from = "fromuser", id = "123" })
				:tag("child1");
			-- Make reply stanza
			local r = st.error_reply(s, "cancel", "service-unavailable", nil, "host");
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(#r.tags, 1);
			assert.are.equal(r.tags[1].tags[1].name, "service-unavailable");
			assert.are.equal(r.tags[1].attr.by, "host");
		end);

		it("should work for <iq get>", function()
			-- Test stanza
			local s = st.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "get" })
				:tag("child1");
			-- Make reply stanza
			local r = st.error_reply(s, "cancel", "service-unavailable");
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(r.attr.type, "error");
			assert.are.equal(#r.tags, 1);
			assert.are.equal(r.tags[1].tags[1].name, "service-unavailable");
		end);

		it("should reject not-stanzas", function ()
			assert.has.error_match(function ()
				st.error_reply(not "a stanza", "modify", "bad-request");
			end, "expected stanza");
		end);

		it("should reject stanzas of type error", function ()
			assert.has.error_match(function ()
				st.error_reply(st.message({type="error"}), "cancel", "conflict");
			end, "got stanza of type error");
			assert.has.error_match(function ()
				st.error_reply(st.error_reply(st.message({type="chat"}), "modify", "forbidden"), "cancel", "service-unavailable");
			end, "got stanza of type error");
		end);

		describe("util.error integration", function ()
		it("should accept util.error objects", function ()
			local s = st.message({ to = "touser", from = "fromuser", id = "123", type = "chat" }, "Hello");
			local e = errors.new({ type = "modify", condition = "not-acceptable", text = "Bork bork bork" }, { by = "this.test" });
			local r = st.error_reply(s, e);

			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(r.attr.type, "error");
			assert.are.equal(r.tags[1].name, "error");
			assert.are.equal(r.tags[1].attr.type, e.type);
			assert.are.equal(r.tags[1].tags[1].name, e.condition);
			assert.are.equal(r.tags[1].tags[2]:get_text(), e.text);
			assert.are.equal("this.test", r.tags[1].attr.by);
		end);

		it("should accept util.error objects with an URI", function ()
			local s = st.message({ to = "touser", from = "fromuser", id = "123", type = "chat" }, "Hello");
			local gone = errors.new({ condition = "gone", extra = { uri = "file:///dev/null" } })
			local gonner = st.error_reply(s, gone);
			assert.are.equal("gone", gonner.tags[1].tags[1].name);
			assert.are.equal("file:///dev/null", gonner.tags[1].tags[1][1]);
		end);

		it("should accept util.error objects with application specific error", function ()
			local s = st.message({ to = "touser", from = "fromuser", id = "123", type = "chat" }, "Hello");
			local e = errors.new({ condition = "internal-server-error", text = "Namespaced thing happened",
				extra = {namespace="xmpp:example.test", condition="this-happened"} })
			local r = st.error_reply(s, e);
			assert.are.equal("xmpp:example.test", r.tags[1].tags[3].attr.xmlns);
			assert.are.equal("this-happened", r.tags[1].tags[3].name);

			local e2 = errors.new({ condition = "internal-server-error", text = "Namespaced thing happened",
				extra = {tag=st.stanza("that-happened", { xmlns = "xmpp:example.test", ["another-attribute"] = "here" })} })
			local r2 = st.error_reply(s, e2);
			assert.are.equal("xmpp:example.test", r2.tags[1].tags[3].attr.xmlns);
			assert.are.equal("that-happened", r2.tags[1].tags[3].name);
			assert.are.equal("here", r2.tags[1].tags[3].attr["another-attribute"]);
		end);
		end);
	end);

	describe("#get_error()", function ()
		describe("basics", function ()
			local s = st.message();
			local e = st.error_reply(s, "cancel", "not-acceptable", "UNACCEPTABLE!!!! ONE MILLION YEARS DUNGEON!")
				:tag("dungeon", { xmlns = "urn:uuid:c9026187-5b05-4e70-b265-c3b6338a7d0f", period="1000000years"});
			local typ, cond, text, extra = e:get_error();
			assert.equal("cancel", typ);
			assert.equal("not-acceptable", cond);
			assert.equal("UNACCEPTABLE!!!! ONE MILLION YEARS DUNGEON!", text);
			assert.not_nil(extra)
		end)
	end)

	describe("#add_error()", function ()
		describe("basics", function ()
			local s = st.stanza("custom", { xmlns = "urn:example:foo" });
			local e = s:add_error("cancel", "not-acceptable", "UNACCEPTABLE!!!! ONE MILLION YEARS DUNGEON!")
				:tag("dungeon", { xmlns = "urn:uuid:c9026187-5b05-4e70-b265-c3b6338a7d0f", period="1000000years"});
			assert.equal(s, e);
			local typ, cond, text, extra = e:get_error();
			assert.equal("cancel", typ);
			assert.equal("not-acceptable", cond);
			assert.equal("UNACCEPTABLE!!!! ONE MILLION YEARS DUNGEON!", text);
			assert.is_nil(extra);
		end)
	end)

	describe("should reject #invalid", function ()
		local invalid_names = {
			["empty string"] = "", ["characters"] = "<>";
		}
		local invalid_data = {
			["number"] = 1234, ["table"] = {};
			["utf8"] = string.char(0xF4, 0x90, 0x80, 0x80);
			["nil"] = "nil"; ["boolean"] = true;
			["control characters"] = "\0\1\2\3";
		};

		for value_type, value in pairs(invalid_names) do
			it(value_type.." in tag names", function ()
				assert.error_matches(function ()
					st.stanza(value);
				end, value_type);
			end);
			it(value_type.." in attribute names", function ()
				assert.error_matches(function ()
					st.stanza("valid", { [value] = "valid" });
				end, value_type);
			end);
		end
		for value_type, value in pairs(invalid_data) do
			if value == "nil" then value = nil; end
			it(value_type.." in tag names", function ()
				assert.error_matches(function ()
					st.stanza(value);
				end, value_type);
			end);
			it(value_type.." in attribute names", function ()
				assert.error_matches(function ()
					st.stanza("valid", { [value] = "valid" });
				end, value_type);
			end);
			if value ~= nil then
				it(value_type.." in attribute values", function ()
					assert.error_matches(function ()
						st.stanza("valid", { valid = value });
					end, value_type);
				end);
				it(value_type.." in text node", function ()
					assert.error_matches(function ()
						st.stanza("valid"):text(value);
					end, value_type);
				end);
			end
		end
	end);

	describe("#is_stanza", function ()
		-- is_stanza(any) -> boolean
		it("identifies stanzas as stanzas", function ()
			assert.truthy(st.is_stanza(st.stanza("x")));
		end);
		it("identifies strings as not stanzas", function ()
			assert.falsy(st.is_stanza(""));
		end);
		it("identifies numbers as not stanzas", function ()
			assert.falsy(st.is_stanza(1));
		end);
		it("identifies tables as not stanzas", function ()
			assert.falsy(st.is_stanza({}));
		end);
	end);

	describe("#remove_children", function ()
		it("should work", function ()
			local s = st.stanza("x", {xmlns="test"})
				:tag("y", {xmlns="test"}):up()
				:tag("z", {xmlns="test2"}):up()
				:tag("x", {xmlns="test2"}):up()

			s:remove_children("x");
			assert.falsy(s:get_child("x"))
			assert.truthy(s:get_child("z","test2"));
			assert.truthy(s:get_child("x","test2"));

			s:remove_children(nil, "test2");
			assert.truthy(s:get_child("y"))
			assert.falsy(s:get_child(nil,"test2"));

			s:remove_children();
			assert.falsy(s.tags[1]);
		end);
	end);

	describe("#maptags", function ()
		it("should work", function ()
			local s = st.stanza("test")
				:tag("one"):up()
				:tag("two"):up()
				:tag("one"):up()
				:tag("three"):up();

			local function one_filter(tag)
				if tag.name == "one" then
					return nil;
				end
				return tag;
			end
			assert.equal(4, #s.tags);
			s:maptags(one_filter);
			assert.equal(2, #s.tags);
		end);

		it("should work with multiple consecutive text nodes", function ()
			local s = st.deserialize({
				"\n";
				{
					"away";
					name = "show";
					attr = {};
				};
				"\n";
				{
					"I am away";
					name = "status";
					attr = {};
				};
				"\n";
				{
					"0";
					name = "priority";
					attr = {};
				};
				"\n";
				{
					name = "c";
					attr = {
						xmlns = "http://jabber.org/protocol/caps";
						node = "http://psi-im.org";
						hash = "sha-1";
					};
				};
				"\n";
				"\n";
				name = "presence";
				attr = {
					to = "user@example.com/jflsjfld";
					from = "room@chat.example.org/nick";
				};
			});

			assert.equal(4, #s.tags);

			s:maptags(function (tag) return tag; end);
			assert.equal(4, #s.tags);

			s:maptags(function (tag)
				if tag.name == "c" then
					return nil;
				end
				return tag;
			end);
			assert.equal(3, #s.tags);
		end);
		it("errors on invalid data - #981", function ()
			local s = st.message({}, "Hello");
			s.tags[1] = st.clone(s.tags[1]);
			assert.has_error_match(function ()
				s:maptags(function () end);
			end, "Invalid stanza");
		end);
	end);

	describe("get_child_with_attr", function ()
		local s = st.message({ type = "chat" })
			:text_tag("body", "Hello world", { ["xml:lang"] = "en" })
			:text_tag("body", "Bonjour le monde", { ["xml:lang"] = "fr" })
			:text_tag("body", "Hallo Welt", { ["xml:lang"] = "de" })

		it("works", function ()
			assert.equal(s:get_child_with_attr("body", nil, "xml:lang", "en"):get_text(), "Hello world");
			assert.equal(s:get_child_with_attr("body", nil, "xml:lang", "de"):get_text(), "Hallo Welt");
			assert.equal(s:get_child_with_attr("body", nil, "xml:lang", "fr"):get_text(), "Bonjour le monde");
			assert.is_nil(s:get_child_with_attr("body", nil, "xml:lang", "FR"));
			assert.is_nil(s:get_child_with_attr("body", nil, "xml:lang", "es"));
		end);

		it("supports normalization", function ()
			assert.equal(s:get_child_with_attr("body", nil, "xml:lang", "EN", string.upper):get_text(), "Hello world");
			assert.is_nil(s:get_child_with_attr("body", nil, "xml:lang", "ES", string.upper));
		end);
	end);

	describe("#clone", function ()
		it("works", function ()
			local s = st.message({type="chat"}, "Hello"):reset();
			local c = st.clone(s);
			assert.same(s, c);
		end);

		it("works", function ()
			assert.has_error(function ()
				st.clone("this is not a stanza");
			end);
		end);
	end);

	describe("top_tag", function ()
		local xml_parse = require "util.xml".parse;
		it("works", function ()
			local s = st.message({type="chat"}, "Hello");
			local top_tag = s:top_tag();
			assert.is_string(top_tag);
			assert.not_equal("/>", top_tag:sub(-2, -1));
			assert.equal(">", top_tag:sub(-1, -1));
			local s2 = xml_parse(top_tag.."</message>");
			assert(st.is_stanza(s2));
			assert.equal("message", s2.name);
			assert.equal(0, #s2);
			assert.equal(0, #s2.tags);
			assert.equal("chat", s2.attr.type);
		end);

		it("works with namespaced attributes", function ()
			local s = xml_parse[[<message foo:bar='true' xmlns:foo='my-awesome-ns'/>]];
			local top_tag = s:top_tag();
			assert.is_string(top_tag);
			assert.not_equal("/>", top_tag:sub(-2, -1));
			assert.equal(">", top_tag:sub(-1, -1));
			local s2 = xml_parse(top_tag.."</message>");
			assert(st.is_stanza(s2));
			assert.equal("message", s2.name);
			assert.equal(0, #s2);
			assert.equal(0, #s2.tags);
			assert.equal("true", s2.attr["my-awesome-ns\1bar"]);
		end);
	end);

	describe("indent", function ()
		local s = st.stanza("foo"):text("\n"):tag("bar"):tag("baz"):up():text_tag("cow", "moo");
		assert.equal("<foo>\n\t<bar>\n\t\t<baz/>\n\t\t<cow>moo</cow>\n\t</bar>\n</foo>", tostring(s:indent()));
		assert.equal("<foo>\n  <bar>\n    <baz/>\n    <cow>moo</cow>\n  </bar>\n</foo>", tostring(s:indent(1, "  ")));
		assert.equal("<foo>\n\t\t<bar>\n\t\t\t<baz/>\n\t\t\t<cow>moo</cow>\n\t\t</bar>\n\t</foo>", tostring(s:indent(2, "\t")));
	end);

	describe("find", function()
		it("works", function()
			local s = st.stanza("root", { attr = "value" }):tag("child",
				{ xmlns = "urn:example:not:same"; childattr = "thisvalue" }):text_tag("nested", "text"):reset();
			assert.equal("value", s:find("@attr"), "finds attr")
			assert.equal(s:get_child("child", "urn:example:not:same"), s:find("{urn:example:not:same}child"),
				"equivalent to get_child")
			assert.equal("thisvalue", s:find("{urn:example:not:same}child@childattr"), "finds child attr")
			assert.equal("text", s:find("{urn:example:not:same}child/nested#"), "finds nested text")
			assert.is_nil(s:find("child"), "respects namespaces")
		end);
		it("handles namespaced attributes", function()
			local s = st.stanza("root", { ["urn:example:namespace\1attr"] = "value" }, { e = "urn:example:namespace" });
			assert.equal("value", s:find("@e:attr"), "finds prefixed attr")
			assert.equal("value", s:find("@{urn:example:namespace}attr"), "finds clark attr")
		end)
	end);
end);
