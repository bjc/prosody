local jwt = require "util.jwt";

describe("util.jwt", function ()
	it("validates", function ()
		local key = "secret";
		local token = jwt.sign(key, { payload = "this" });
		assert.string(token);
		local ok, parsed = jwt.verify(key, token);
		assert.truthy(ok)
		assert.same({ payload = "this" }, parsed);
	end);
	it("rejects invalid", function ()
		local key = "secret";
		local token = jwt.sign("wrong", { payload = "this" });
		assert.string(token);
		local ok, err = jwt.verify(key, token);
		assert.falsy(ok)
	end);
end);

