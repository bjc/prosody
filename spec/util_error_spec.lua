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

	describe("is_err()", function ()
		it("works", function ()
			assert.truthy(errors.is_err(errors.new()));
			assert.falsy(errors.is_err("not an error"));
		end);
	end);

	describe("coerce", function ()
		it("works", function ()
			local ok, err = errors.coerce(nil, "it dun goofed");
			assert.is_nil(ok);
			assert.truthy(errors.is_err(err))
		end);
	end);

	describe("from_stanza", function ()
		it("works", function ()
			local st = require "util.stanza";
			local m = st.message({ type = "chat" });
			local e = st.error_reply(m, "modify", "bad-request", nil, "error.example"):tag("extra", { xmlns = "xmpp:example.test" });
			local err = errors.from_stanza(e);
			assert.truthy(errors.is_err(err));
			assert.equal("modify", err.type);
			assert.equal("bad-request", err.condition);
			assert.equal(e, err.context.stanza);
			assert.equal("error.example", err.context.by);
			assert.not_nil(err.extra.tag);
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
			local reg = errors.init("test", {
				namespace = "spec";
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
	end);

end);

