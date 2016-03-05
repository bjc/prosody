function parse(parse)
	local x =
[[<x xmlns:a="b">
	<y xmlns:a="c"> <!-- this overwrites 'a' -->
	    <a:z/>
	</y>
	<a:z/> <!-- prefix 'a' is nil here, but should be 'b' -->
</x>
]]
	local stanza = parse(x);
	assert_equal(stanza.tags[2].attr.xmlns, "b");
	assert_equal(stanza.tags[2].namespaces["a"], "b");
end
