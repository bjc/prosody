describe("parse", function()
	local parse
	setup(function() parse = require"util.argparse".parse; end);

	it("works", function()
		-- basic smoke test
		local opts = parse({ "--help" });
		assert.same({ help = true }, opts);
	end);

	it("returns if no args", function() assert.same({}, parse({})); end);

	it("supports boolean flags", function()
		local opts, err = parse({ "--foo"; "--no-bar" });
		assert.falsy(err);
		assert.same({ foo = true; bar = false }, opts);
	end);

	it("consumes input until the first argument", function()
		local arg = { "--foo"; "bar"; "--baz" };
		local opts, err = parse(arg);
		assert.falsy(err);
		assert.same({ foo = true }, opts);
		assert.same({ "bar"; "--baz" }, arg);
	end);

	it("expands short options", function()
		local opts, err = parse({ "--foo"; "-b" }, { short_params = { b = "bar" } });
		assert.falsy(err);
		assert.same({ foo = true; bar = true }, opts);
	end);

	it("supports value arguments", function()
		local opts, err = parse({ "--foo"; "bar"; "--baz=moo" }, { value_params = { foo = true; bar = true } });
		assert.falsy(err);
		assert.same({ foo = "bar"; baz = "moo" }, opts);
	end);

	it("demands values for value params", function()
		local opts, err, where = parse({ "--foo" }, { value_params = { foo = true } });
		assert.falsy(opts);
		assert.equal("missing-value", err);
		assert.equal("--foo", where);
	end);

end);
