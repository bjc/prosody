local dataforms = require "util.dataforms";
local st = require "util.stanza";
local jid = require "util.jid";
local iter = require "util.iterators";

describe("util.dataforms", function ()
	local some_form, xform;
	setup(function ()
		some_form = dataforms.new({
			title = "form-title",
			instructions = "form-instructions",
			{
				type = "hidden",
				name = "FORM_TYPE",
				value = "xmpp:prosody.im/spec/util.dataforms#1",
			};
			{
				type = "fixed";
				value = "Fixed field";
			},
			{
				type = "boolean",
				label = "boolean-label",
				name = "boolean-field",
				value = true,
			},
			{
				type = "fixed",
				label = "fixed-label",
				name = "fixed-field",
				value = "fixed-value",
			},
			{
				type = "hidden",
				label = "hidden-label",
				name = "hidden-field",
				value = "hidden-value",
			},
			{
				type = "jid-multi",
				label = "jid-multi-label",
				name = "jid-multi-field",
				value = {
					"jid@multi/value#1",
					"jid@multi/value#2",
				},
			},
			{
				type = "jid-single",
				label = "jid-single-label",
				name = "jid-single-field",
				value = "jid@single/value",
			},
			{
				type = "list-multi",
				label = "list-multi-label",
				name = "list-multi-field",
				value = {
					"list-multi-option-value#1",
					"list-multi-option-value#3",
				},
				options = {
					{
						label = "list-multi-option-label#1",
						value = "list-multi-option-value#1",
						default = true,
					},
					{
						label = "list-multi-option-label#2",
						value = "list-multi-option-value#2",
						default = false,
					},
					{
						label = "list-multi-option-label#3",
						value = "list-multi-option-value#3",
						default = true,
					},
				}
			},
			{
				type = "list-single",
				label = "list-single-label",
				name = "list-single-field",
				value = "list-single-value",
				options = {
					"list-single-value",
					"list-single-value#2",
					"list-single-value#3",
				}
			},
			{
				type = "text-multi",
				label = "text-multi-label",
				name = "text-multi-field",
				value = "text\nmulti\nvalue",
			},
			{
				type = "text-private",
				label = "text-private-label",
				name = "text-private-field",
				value = "text-private-value",
			},
			{
				type = "text-single",
				label = "text-single-label",
				name = "text-single-field",
				value = "text-single-value",
			},
			{
				-- XEP-0221
				-- TODO Validate the XML produced by this.
				type = "text-single",
				label = "text-single-with-media-label",
				name = "text-single-with-media-field",
				media = {
					height = 24,
					width = 32,
					{
						type = "image/png",
						uri = "data:",
					},
				},
			},
		});
		xform = some_form:form();
	end);

	it("XML serialization looks like it should", function ()
		assert.truthy(xform);
		assert.truthy(st.is_stanza(xform));
		assert.equal("x", xform.name);
		assert.equal("jabber:x:data", xform.attr.xmlns);
		assert.equal("FORM_TYPE", xform:find("field@var"));
		assert.equal("xmpp:prosody.im/spec/util.dataforms#1", xform:find("field/value#"));
		local allowed_direct_children = {
			title = true,
			instructions = true,
			field = true,
		}
		for tag in xform:childtags() do
			assert.truthy(allowed_direct_children[tag.name], "unknown direct child");
		end
	end);

	it("produced boolean field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "boolean-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("boolean-field", f.attr.var);
		assert.equal("boolean", f.attr.type);
		assert.equal("boolean-label", f.attr.label);
		assert.equal(1, iter.count(f:childtags("value")));
		local val = f:get_child_text("value");
		assert.truthy(val == "true" or val == "1");
	end);

	it("produced fixed field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "fixed-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("fixed-field", f.attr.var);
		assert.equal("fixed", f.attr.type);
		assert.equal("fixed-label", f.attr.label);
		assert.equal(1, iter.count(f:childtags("value")));
		assert.equal("fixed-value", f:get_child_text("value"));
	end);

	it("produced hidden field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "hidden-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("hidden-field", f.attr.var);
		assert.equal("hidden", f.attr.type);
		assert.equal("hidden-label", f.attr.label);
		assert.equal(1, iter.count(f:childtags("value")));
		assert.equal("hidden-value", f:get_child_text("value"));
	end);

	it("produced jid-multi field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "jid-multi-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("jid-multi-field", f.attr.var);
		assert.equal("jid-multi", f.attr.type);
		assert.equal("jid-multi-label", f.attr.label);
		assert.equal(2, iter.count(f:childtags("value")));

		local i = 0;
		for value in f:childtags("value") do
			i = i + 1;
			assert.equal(("jid@multi/value#%d"):format(i), value:get_text());
		end
	end);

	it("produced jid-single field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "jid-single-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("jid-single-field", f.attr.var);
		assert.equal("jid-single", f.attr.type);
		assert.equal("jid-single-label", f.attr.label);
		assert.equal(1, iter.count(f:childtags("value")));
		assert.equal("jid@single/value", f:get_child_text("value"));
		assert.truthy(jid.prep(f:get_child_text("value")));
	end);

	it("produced list-multi field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "list-multi-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("list-multi-field", f.attr.var);
		assert.equal("list-multi", f.attr.type);
		assert.equal("list-multi-label", f.attr.label);
		assert.equal(2, iter.count(f:childtags("value")));
		assert.equal("list-multi-option-value#1", f:get_child_text("value"));
		assert.equal(3, iter.count(f:childtags("option")));
	end);

	it("produced list-single field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "list-single-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("list-single-field", f.attr.var);
		assert.equal("list-single", f.attr.type);
		assert.equal("list-single-label", f.attr.label);
		assert.equal(1, iter.count(f:childtags("value")));
		assert.equal("list-single-value", f:get_child_text("value"));
		assert.equal(3, iter.count(f:childtags("option")));
	end);

	it("produced text-multi field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "text-multi-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("text-multi-field", f.attr.var);
		assert.equal("text-multi", f.attr.type);
		assert.equal("text-multi-label", f.attr.label);
		assert.equal(3, iter.count(f:childtags("value")));
	end);

	it("produced text-private field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "text-private-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("text-private-field", f.attr.var);
		assert.equal("text-private", f.attr.type);
		assert.equal("text-private-label", f.attr.label);
		assert.equal(1, iter.count(f:childtags("value")));
		assert.equal("text-private-value", f:get_child_text("value"));
	end);

	it("produced text-single field correctly", function ()
		local f;
		for field in xform:childtags("field") do
			if field.attr.var == "text-single-field" then
				f = field;
				break;
			end
		end

		assert.truthy(st.is_stanza(f));
		assert.equal("text-single-field", f.attr.var);
		assert.equal("text-single", f.attr.type);
		assert.equal("text-single-label", f.attr.label);
		assert.equal(1, iter.count(f:childtags("value")));
		assert.equal("text-single-value", f:get_child_text("value"));
	end);

	describe("get_type()", function ()
		it("identifes dataforms", function ()
			assert.equal(nil, dataforms.get_type(nil));
			assert.equal(nil, dataforms.get_type(""));
			assert.equal(nil, dataforms.get_type({}));
			assert.equal(nil, dataforms.get_type(st.stanza("no-a-form")));
			assert.equal("xmpp:prosody.im/spec/util.dataforms#1", dataforms.get_type(xform));
		end);
	end);

	describe(":data", function ()
		it("returns something", function ()
			assert.truthy(some_form:data(xform));
		end);
	end);

	describe("issue1177", function ()
		local form_with_stuff;
		setup(function ()
			form_with_stuff = dataforms.new({
				{
					type = "list-single";
					name = "abtest";
					label = "A or B?";
					options = {
						{ label = "A", value = "a", default = true },
						{ label = "B", value = "b" },
					};
				},
			});
		end);

		it("includes options when value is included", function ()
			local f = form_with_stuff:form({ abtest = "a" });
			assert.truthy(f:find("field/option"));
		end);

		it("includes options when value is excluded", function ()
			local f = form_with_stuff:form({});
			assert.truthy(f:find("field/option"));
		end);
	end);

	describe("using current values in place of missing fields", function ()
		it("gets back the previous values when given an empty form", function ()
			local current = {
				["list-multi-field"] = {
					"list-multi-option-value#2";
				};
				["list-single-field"] = "list-single-value#2";
				["hidden-field"] = "hidden-value";
				["boolean-field"] = false;
				["text-multi-field"] = "words\ngo\nhere";
				["jid-single-field"] = "alice@example.com";
				["text-private-field"] = "hunter2";
				["text-single-field"] = "text-single-value";
				["jid-multi-field"] = {
					"bob@example.net";
				};
			};
			local expect = {
				-- FORM_TYPE = "xmpp:prosody.im/spec/util.dataforms#1"; -- does this need to be included?
				["list-multi-field"] = {
					"list-multi-option-value#2";
				};
				["list-single-field"] = "list-single-value#2";
				["hidden-field"] = "hidden-value";
				["boolean-field"] = false;
				["text-multi-field"] = "words\ngo\nhere";
				["jid-single-field"] = "alice@example.com";
				["text-private-field"] = "hunter2";
				["text-single-field"] = "text-single-value";
				["jid-multi-field"] = {
					"bob@example.net";
				};
			};
			local data, err = some_form:data(st.stanza("x", {xmlns="jabber:x:data"}), current);
			assert.is.table(data, err);
			assert.same(expect, data, "got back the same data");
		end);
	end);

	describe("field 'var' property", function ()
		it("works as expected", function ()
			local f = dataforms.new {
				{
					var = "someprefix#the-field",
					name = "the_field",
					type = "text-single",
				}
			};
			local x = f:form({the_field = "hello"});
			assert.equal("someprefix#the-field", x:find"field@var");
			assert.equal("hello", x:find"field/value#");
		end);
	end);

	describe("datatype validation", function ()
		local f = dataforms.new {
			{
				name = "number",
				type = "text-single",
				datatype = "xs:integer",
			},
		};

		it("integer roundtrip works", function ()
			local d = f:data(f:form({number = 1}));
			assert.equal(1, d.number);
		end);

		it("integer error handling works", function ()
			local d,e = f:data(f:form({number = "nan"}));
			assert.not_equal(1, d.number);
			assert.table(e);
			assert.string(e.number);
		end);
	end);
end);

