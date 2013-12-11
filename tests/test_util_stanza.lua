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
