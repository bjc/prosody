
local st = require "util.stanza";

describe("util.stanza", function()
	describe("#preserialize()", function()
		it("should work", function()
			local stanza = st.stanza("message", { a = "a" });
			local stanza2 = st.preserialize(stanza);
			assert.is_string(stanza2 and stanza.name, "preserialize returns a stanza");
			assert.is_nil(stanza2.tags, "Preserialized stanza has no tag list");
			assert.is_nil(stanza2.last_add, "Preserialized stanza has no last_add marker");
			assert.is_nil(getmetatable(stanza2), "Preserialized stanza has no metatable");
		end);
	end);

	describe("#preserialize()", function()
		it("should work", function()
			local stanza = st.stanza("message", { a = "a" });
			local stanza2 = st.deserialize(st.preserialize(stanza));
			assert.is_string(stanza2 and stanza.name, "deserialize returns a stanza");
			assert.is_table(stanza2.attr, "Deserialized stanza has attributes");
			assert.are.equal(stanza2.attr.a, "a", "Deserialized stanza retains attributes");
			assert.is_table(getmetatable(stanza2), "Deserialized stanza has metatable");
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
	end);

	describe("#message()", function()
		it("should work", function()
			local m = st.message();
			assert.are.equal(m.name, "message");
		end);
	end);

	describe("#iq()", function()
		it("should work", function()
			local i = st.iq();
			assert.are.equal(i.name, "iq");
		end);
	end);

	describe("#iq()", function()
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
	end);

	describe("#error_reply()", function()
		it("should work for <s>", function()
			-- Test stanza
			local s = st.stanza("s", { to = "touser", from = "fromuser", id = "123" })
				:tag("child1");
			-- Make reply stanza
			local r = st.error_reply(s);
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(#r.tags, 1);
		end);

		it("should work for <iq get>", function()
			-- Test stanza
			local s = st.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "get" })
				:tag("child1");
			-- Make reply stanza
			local r = st.error_reply(s);
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(r.attr.type, "error");
			assert.are.equal(#r.tags, 1);
		end);
	end);
end);
