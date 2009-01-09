
function deserialize(deserialize, st)
	local stanza = st.stanza("message", { a = "a" });
	
	local stanza2 = deserialize(st.preserialize(stanza));
	assert_is(stanza2.last_add, "Deserialized stanza is missing last_add for adding child tags");
end
