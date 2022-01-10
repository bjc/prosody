
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
			local stanza = xml.parse(x, {allow_comments = true});
			assert.are.equal(stanza.tags[2].attr.xmlns, "b");
			assert.are.equal(stanza.tags[2].namespaces["a"], "b");
		end);

		it("should reject doctypes", function()
			local x = "<!DOCTYPE foo []><foo/>";
			local ok = xml.parse(x);
			assert.falsy(ok);
		end);

		it("should reject comments by default", function()
			local x = "<foo><!-- foo --></foo>";
			local ok = xml.parse(x);
			assert.falsy(ok);
		end);

		it("should allow comments if asked nicely", function()
			local x = "<foo><!-- foo --></foo>";
			local stanza = xml.parse(x, {allow_comments = true});
			assert.are.equal(stanza.name, "foo");
			assert.are.equal(#stanza, 0);
		end);

		it("should reject processing instructions", function()
			local x = "<foo><?php die(); ?></foo>";
			local ok = xml.parse(x);
			assert.falsy(ok);
		end);

		it("should allow an xml declaration", function()
			local x = "<?xml version='1.0'?><foo/>";
			local stanza = xml.parse(x);
			assert.truthy(stanza);
			assert.are.equal(stanza.name, "foo");
		end);
	end);
end);
