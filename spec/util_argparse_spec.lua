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
		assert.same({ foo = true, "bar", "--baz" }, opts);
		assert.same({ "bar"; "--baz" }, arg);
	end);

	it("allows continuation beyond first positional argument", function()
		local arg = { "--foo"; "bar"; "--baz" };
		local opts, err = parse(arg, { stop_on_positional = false });
		assert.falsy(err);
		assert.same({ foo = true, baz = true, "bar" }, opts);
		-- All input should have been consumed:
		assert.same({ }, arg);
	end);

	it("expands short options", function()
		do
			local opts, err = parse({ "--foo"; "-b" }, { short_params = { b = "bar" } });
			assert.falsy(err);
			assert.same({ foo = true; bar = true }, opts);
		end

		do
			-- Same test with strict mode enabled and all parameters declared
			local opts, err = parse({ "--foo"; "-b" }, { kv_params = { foo = true, bar = true }; short_params = { b = "bar" }, strict = true });
			assert.falsy(err);
			assert.same({ foo = true; bar = true }, opts);
		end
	end);

	it("supports value arguments", function()
		local opts, err = parse({ "--foo"; "bar"; "--baz=moo" }, { value_params = { foo = true; bar = true } });
		assert.falsy(err);
		assert.same({ foo = "bar"; baz = "moo" }, opts);
	end);

	it("supports value arguments in strict mode", function()
		local opts, err = parse({ "--foo"; "bar"; "--baz=moo" }, { strict = true, value_params = { foo = true; baz = true } });
		assert.falsy(err);
		assert.same({ foo = "bar"; baz = "moo" }, opts);
	end);

	it("demands values for value params", function()
		local opts, err, where = parse({ "--foo" }, { value_params = { foo = true } });
		assert.falsy(opts);
		assert.equal("missing-value", err);
		assert.equal("--foo", where);
	end);

	it("reports where the problem is", function()
		local opts, err, where = parse({ "-h" });
		assert.falsy(opts);
		assert.equal("param-not-found", err);
		assert.equal("-h", where, "returned where");
	end);

	it("supports array arguments", function ()
		do
			local opts, err = parse({ "--item"; "foo"; "--item"; "bar" }, { array_params = { item = true } });
			assert.falsy(err);
			assert.same({"foo","bar"}, opts.item);
		end

		do
			-- Same test with strict mode enabled
			local opts, err = parse({ "--item"; "foo"; "--item"; "bar" }, { array_params = { item = true }, strict = true });
			assert.falsy(err);
			assert.same({"foo","bar"}, opts.item);
		end
	end)

	it("rejects unknown parameters in strict mode", function ()
		local opts, err, err2 = parse({ "--item"; "foo"; "--item"; "bar", "--foobar" }, { array_params = { item = true }, strict = true });
		assert.falsy(opts);
		assert.same("param-not-found", err);
		assert.same("--foobar", err2);
	end);

	it("accepts known kv parameters in strict mode", function ()
		local opts, err = parse({ "--item=foo" }, { kv_params = { item = true }, strict = true });
		assert.falsy(err);
		assert.same("foo", opts.item);
	end);
end);
