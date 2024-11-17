local st = require "prosody.util.stanza";
local xtemplate = require "prosody.util.xtemplate";

describe("util.xtemplate", function ()
	describe("render()", function ()
		it("works", function ()
			assert.same("Hello", xtemplate.render("{greeting}", st.stanza("root"):text_tag("greeting", "Hello")), "regular text content")
			assert.same("Hello", xtemplate.render("{#}", st.stanza("root"):text("Hello")), "top tag text content")
			assert.same("Hello", xtemplate.render("{greeting/@en}", st.stanza("root"):tag("greeting", { en = "Hello" })), "attribute")
		end)
		it("supports conditionals", function ()
			local atom_tmpl = "{@pubsub:title|and{*{@pubsub:title}*\n\n}}{summary|or{{author/name|and{{author/name} posted }}{title}}}";
			local atom_data = st.stanza("entry", { xmlns = "http://www.w3.org/2005/Atom" }, {["pubsub"] = "http://jabber.org/protocol/pubsub"});
			assert.same("", xtemplate.render(atom_tmpl, atom_data));

			atom_data:text_tag("title", "an Entry")
			assert.same("an Entry", xtemplate.render(atom_tmpl, atom_data));

			atom_data:tag("author"):text_tag("name","Juliet"):up();
			assert.same("Juliet posted an Entry", xtemplate.render(atom_tmpl, atom_data));

			atom_data:text_tag("summary", "Juliet just posted a new entry");
			assert.same("Juliet just posted a new entry", xtemplate.render(atom_tmpl, atom_data));

			atom_data.attr["http://jabber.org/protocol/pubsub\1title"] = "Juliets musings";
			assert.same("*Juliets musings*\n\nJuliet just posted a new entry", xtemplate.render(atom_tmpl, atom_data));
		end)
		it("can strip surrounding whitespace", function ()
			assert.same("Hello ", xtemplate.render(" {-greeting} ", st.stanza("root"):text_tag("greeting", "Hello")))
			assert.same(" Hello", xtemplate.render(" {greeting-} ", st.stanza("root"):text_tag("greeting", "Hello")))
			assert.same("Hello", xtemplate.render(" {-greeting-} ", st.stanza("root"):text_tag("greeting", "Hello")))
		end)
		describe("each", function ()
			it("makes sense", function ()
				local x = st.stanza("root"):tag("foo"):tag("bar")
				for i = 1, 5 do x:text_tag("i", tostring(i)); end
				x:reset();
				assert.same("12345", xtemplate.render("{foo/bar|each(i){{#}}}", x));
			end)
			it("handles missing inputs", function ()
				local x = st.stanza("root");
				assert.same("", xtemplate.render("{foo/bar|each(i){{#}}}", x));
			end)
		end)
	end)
end)
