-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


function preserialize(preserialize, st)
	local stanza = st.stanza("message", { a = "a" });
	local stanza2 = preserialize(stanza);
	assert_is(stanza2 and stanza.name, "preserialize returns a stanza");
	assert_is_not(stanza2.tags, "Preserialized stanza has no tag list");
	assert_is_not(stanza2.last_add, "Preserialized stanza has no last_add marker");
	assert_is_not(getmetatable(stanza2), "Preserialized stanza has no metatable");
end

function deserialize(deserialize, st)
	local stanza = st.stanza("message", { a = "a" });

	local stanza2 = deserialize(st.preserialize(stanza));
	assert_is(stanza2 and stanza.name, "deserialize returns a stanza");
	assert_table(stanza2.attr, "Deserialized stanza has attributes");
	assert_equal(stanza2.attr.a, "a", "Deserialized stanza retains attributes");
	assert_table(getmetatable(stanza2), "Deserialized stanza has metatable");
end

function stanza(stanza)
	local s = stanza("foo", { xmlns = "myxmlns", a = "attr-a" });
	assert_equal(s.name, "foo");
	assert_equal(s.attr.xmlns, "myxmlns");
	assert_equal(s.attr.a, "attr-a");

	local s1 = stanza("s1");
	assert_equal(s1.name, "s1");
	assert_equal(s1.attr.xmlns, nil);
	assert_equal(#s1, 0);
	assert_equal(#s1.tags, 0);
	
	s1:tag("child1");
	assert_equal(#s1.tags, 1);
	assert_equal(s1.tags[1].name, "child1");

	s1:tag("grandchild1"):up();
	assert_equal(#s1.tags, 1);
	assert_equal(s1.tags[1].name, "child1");
	assert_equal(#s1.tags[1], 1);
	assert_equal(s1.tags[1][1].name, "grandchild1");
	
	s1:up():tag("child2");
	assert_equal(#s1.tags, 2, tostring(s1));
	assert_equal(s1.tags[1].name, "child1");
	assert_equal(s1.tags[2].name, "child2");
	assert_equal(#s1.tags[1], 1);
	assert_equal(s1.tags[1][1].name, "grandchild1");

	s1:up():text("Hello world");
	assert_equal(#s1.tags, 2);
	assert_equal(#s1, 3);
	assert_equal(s1.tags[1].name, "child1");
	assert_equal(s1.tags[2].name, "child2");
	assert_equal(#s1.tags[1], 1);
	assert_equal(s1.tags[1][1].name, "grandchild1");
end

function message(message)
	local m = message();
	assert_equal(m.name, "message");
end

function iq(iq)
	local i = iq();
	assert_equal(i.name, "iq");
end

function presence(presence)
	local p = presence();
	assert_equal(p.name, "presence");
end

function reply(reply, _M)
	do
		-- Test stanza
		local s = _M.stanza("s", { to = "touser", from = "fromuser", id = "123" })
			:tag("child1");
		-- Make reply stanza
		local r = reply(s);
		assert_equal(r.name, s.name);
		assert_equal(r.id, s.id);
		assert_equal(r.attr.to, s.attr.from);
		assert_equal(r.attr.from, s.attr.to);
		assert_equal(#r.tags, 0, "A reply should not include children of the original stanza");
	end

	do
		-- Test stanza
		local s = _M.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "get" })
			:tag("child1");
		-- Make reply stanza
		local r = reply(s);
		assert_equal(r.name, s.name);
		assert_equal(r.id, s.id);
		assert_equal(r.attr.to, s.attr.from);
		assert_equal(r.attr.from, s.attr.to);
		assert_equal(r.attr.type, "result");
		assert_equal(#r.tags, 0, "A reply should not include children of the original stanza");
	end

	do
		-- Test stanza
		local s = _M.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "set" })
			:tag("child1");
		-- Make reply stanza
		local r = reply(s);
		assert_equal(r.name, s.name);
		assert_equal(r.id, s.id);
		assert_equal(r.attr.to, s.attr.from);
		assert_equal(r.attr.from, s.attr.to);
		assert_equal(r.attr.type, "result");
		assert_equal(#r.tags, 0, "A reply should not include children of the original stanza");
	end
end

function error_reply(error_reply, _M)
	do
		-- Test stanza
		local s = _M.stanza("s", { to = "touser", from = "fromuser", id = "123" })
			:tag("child1");
		-- Make reply stanza
		local r = error_reply(s);
		assert_equal(r.name, s.name);
		assert_equal(r.id, s.id);
		assert_equal(r.attr.to, s.attr.from);
		assert_equal(r.attr.from, s.attr.to);
		assert_equal(#r.tags, 1);
	end

	do
		-- Test stanza
		local s = _M.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "get" })
			:tag("child1");
		-- Make reply stanza
		local r = error_reply(s);
		assert_equal(r.name, s.name);
		assert_equal(r.id, s.id);
		assert_equal(r.attr.to, s.attr.from);
		assert_equal(r.attr.from, s.attr.to);
		assert_equal(r.attr.type, "error");
		assert_equal(#r.tags, 1);
	end
end
