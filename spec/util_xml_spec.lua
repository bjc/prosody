
local xml = require "util.xml";

describe("util.xml", function()
	describe("#parse()", function()
		it("should work", function()
			local x =
[[<x xmlns:a="b">
	<y xmlns:a="c"> <!-- this overwrites 'a' -->
	    <a:z/>
	</y>
	<a:z/> <!-- prefix 'a' is nil here, but should be 'b' -->
</x>
]]
			local stanza = xml.parse(x);
			assert.are.equal(stanza.tags[2].attr.xmlns, "b");
			assert.are.equal(stanza.tags[2].namespaces["a"], "b");
		end);
	end);
end);
