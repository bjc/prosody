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
			local e = st.error_reply(m, "modify", "bad-request");
			local err = errors.from_stanza(e);
			assert.truthy(errors.is_err(err));
			assert.equal("modify", err.type);
			assert.equal("bad-request", err.condition);
			assert.equal(e, err.context.stanza);
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

end);

