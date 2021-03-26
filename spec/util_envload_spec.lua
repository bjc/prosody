describe("util.envload", function()
	local envload = require "util.envload";
	describe("envload()", function()
		it("works", function()
			local f, err = envload.envload("return 'hello'", "@test", {});
			assert.is_function(f, err);
			local ok, ret = pcall(f);
			assert.truthy(ok);
			assert.equal("hello", ret);
		end);
		it("lets you pass values in and out", function ()
			local f, err = envload.envload("return thisglobal", "@test", { thisglobal = "yes, this one" });
			assert.is_function(f, err);
			local ok, ret = pcall(f);
			assert.truthy(ok);
			assert.equal("yes, this one", ret);

		end);

	end)
	-- TODO envloadfile()
end)
