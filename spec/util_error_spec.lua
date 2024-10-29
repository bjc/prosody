local errors = require "util.error"

describe("util.error", function ()
	describe("new()", function ()
		it("works", function ()
			local err = errors.new("bork", "bork bork");
			assert.not_nil(err);
			assert.equal("cancel", err.type);
			assert.equal("undefined-condition", err.condition);
			assert.same("bork bork", err.context);
		end);

		describe("templates", function ()
			it("works", function ()
				local templates = {
					["fail"] = {
						type = "wait",
						condition = "internal-server-error",
						code = 555;
					};
				};
				local err = errors.new("fail", { traceback = "in some file, somewhere" }, templates);
				assert.equal("wait", err.type);
				assert.equal("internal-server-error", err.condition);
				assert.equal(555, err.code);
				assert.same({ traceback = "in some file, somewhere" }, err.context);
			end);
		end);

	end);

	describe("is_error()", function ()
		it("works", function ()
			assert.truthy(errors.is_error(errors.new()));
			assert.falsy(errors.is_error("not an error"));
		end);
	end);

	describe("coerce", function ()
		it("works", function ()
			local ok, err = errors.coerce(nil, "it dun goofed");
			assert.is_nil(ok);
			assert.truthy(errors.is_error(err))
		end);
	end);

	describe("from_stanza", function ()
		it("works", function ()
			local st = require "util.stanza";
			local m = st.message({ type = "chat" });
			local e = st.error_reply(m, "modify", "bad-request", nil, "error.example"):tag("extra", { xmlns = "xmpp:example.test" });
			local err = errors.from_stanza(e);
			assert.truthy(errors.is_error(err));
			assert.equal("modify", err.type);
			assert.equal("bad-request", err.condition);
			assert.equal(e, err.context.stanza);
			assert.equal("error.example", err.context.by);
			assert.not_nil(err.extra.tag);
			assert.not_has_error(function ()
				errors.from_stanza(st.message())
			end);
		end);
	end);

	describe("__tostring", function ()
		it("doesn't throw", function ()
			assert.has_no.errors(function ()
				-- See 6f317e51544d
				tostring(errors.new());
			end);
		end);
	end);

	describe("extra", function ()
		it("keeps some extra fields", function ()
			local err = errors.new({condition="gone",text="Sorry mate, it's all gone",extra={uri="file:///dev/null"}});
			assert.is_table(err.extra);
			assert.equal("file:///dev/null", err.extra.uri);
		end);
	end)

	describe("init", function()
		it("basics works", function()
			local reg = errors.init("test", {
				broke = {type = "cancel"; condition = "internal-server-error"; text = "It broke :("};
				nope = {type = "auth"; condition = "not-authorized"; text = "Can't let you do that Dave"};
			});

			local broke = reg.new("broke");
			assert.equal("cancel", broke.type);
			assert.equal("internal-server-error", broke.condition);
			assert.equal("It broke :(", broke.text);
			assert.equal("test", broke.source);

			local nope = reg.new("nope");
			assert.equal("auth", nope.type);
			assert.equal("not-authorized", nope.condition);
			assert.equal("Can't let you do that Dave", nope.text);
		end);

		it("compact mode works", function()
			local reg = errors.init("test", "spec", {
				broke = {"cancel"; "internal-server-error"; "It broke :("};
				nope = {"auth"; "not-authorized"; "Can't let you do that Dave"; "sorry-dave"};
			});

			local broke = reg.new("broke");
			assert.equal("cancel", broke.type);
			assert.equal("internal-server-error", broke.condition);
			assert.equal("It broke :(", broke.text);
			assert.is_nil(broke.extra);

			local nope = reg.new("nope");
			assert.equal("auth", nope.type);
			assert.equal("not-authorized", nope.condition);
			assert.equal("Can't let you do that Dave", nope.text);
			assert.equal("spec", nope.extra.namespace);
			assert.equal("sorry-dave", nope.extra.condition);
		end);

		it("registry looks the same regardless of syntax", function()
			local normal = errors.init("test", {
				broke = {type = "cancel"; condition = "internal-server-error"; text = "It broke :("};
				nope = {
					type = "auth";
					condition = "not-authorized";
					text = "Can't let you do that Dave";
					extra = {namespace = "spec"; condition = "sorry-dave"};
				};
			});
			local compact1 = errors.init("test", "spec", {
				broke = {"cancel"; "internal-server-error"; "It broke :("};
				nope = {"auth"; "not-authorized"; "Can't let you do that Dave"; "sorry-dave"};
			});
			local compact2 = errors.init("test", {
				broke = {"cancel"; "internal-server-error"; "It broke :("};
				nope = {"auth"; "not-authorized"; "Can't let you do that Dave"};
			});
			assert.same(normal.registry, compact1.registry);

			assert.same({
				broke = {type = "cancel"; condition = "internal-server-error"; text = "It broke :("};
				nope = {type = "auth"; condition = "not-authorized"; text = "Can't let you do that Dave"};
			}, compact2.registry);
		end);

		describe(".wrap", function ()
			local reg = errors.init("test", "spec", {
				myerror = { "cancel", "internal-server-error", "Oh no" };
			});
			it("is exposed", function ()
				assert.is_function(reg.wrap);
			end);
			it("returns errors according to the registry", function ()
				local e = reg.wrap("myerror");
				assert.equal("cancel", e.type);
				assert.equal("internal-server-error", e.condition);
				assert.equal("Oh no", e.text);
			end);

			it("passes through existing errors", function ()
				local e = reg.wrap(reg.new({ type = "auth", condition = "forbidden" }));
				assert.equal("auth", e.type);
				assert.equal("forbidden", e.condition);
			end);

			it("wraps arbitrary values", function ()
				local e = reg.wrap(123);
				assert.equal("cancel", e.type);
				assert.equal("undefined-condition", e.condition);
				assert.equal(123, e.context.wrapped_error);
			end);
		end);

		describe(".coerce", function ()
			local reg = errors.init("test", "spec", {
				myerror = { "cancel", "internal-server-error", "Oh no" };
			});

			it("is exposed", function ()
				assert.is_function(reg.coerce);
			end);

			it("passes through existing errors", function ()
				local function test()
					return nil, errors.new({ type = "auth", condition = "forbidden" });
				end
				local ok, err = reg.coerce(test());
				assert.is_nil(ok);
				assert.is_truthy(errors.is_error(err));
				assert.equal("forbidden", err.condition);
			end);

			it("passes through successful return values", function ()
				local function test()
					return 1, 2, 3, 4;
				end
				local one, two, three, four = reg.coerce(test());
				assert.equal(1, one);
				assert.equal(2, two);
				assert.equal(3, three);
				assert.equal(4, four);
			end);

			it("wraps non-error objects", function ()
				local function test()
					return nil, "myerror";
				end
				local ok, err = reg.coerce(test());
				assert.is_nil(ok);
				assert.is_truthy(errors.is_error(err));
				assert.equal("internal-server-error", err.condition);
				assert.equal("Oh no", err.text);
			end);
		end);
	end);

end);

