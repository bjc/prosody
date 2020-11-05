local sep = package.config:match("(.)\n");
describe("util.paths", function ()
	local paths = require "util.paths";
	describe("#join()", function ()
		it("returns single component as-is", function ()
			assert.equal("foo", paths.join("foo"));
		end);
		it("joins paths", function ()
			assert.equal("foo"..sep.."bar", paths.join("foo", "bar"))
		end);
		it("joins longer paths", function ()
			assert.equal("foo"..sep.."bar"..sep.."baz", paths.join("foo", "bar", "baz"))
		end);
		it("joins even longer paths", function ()
			assert.equal("foo"..sep.."bar"..sep.."baz"..sep.."moo", paths.join("foo", "bar", "baz", "moo"))
		end);
	end)

	describe("#glob_to_pattern()", function ()
		it("works", function ()
			assert.equal("^thing.%..*$", paths.glob_to_pattern("thing?.*"))
		end);
	end)

	describe("#resolve_relative_path()", function ()
		it("returns absolute paths as-is", function ()
			if sep == "/" then
				assert.equal("/tmp/path", paths.resolve_relative_path("/run", "/tmp/path"));
			elseif sep == "\\" then
				assert.equal("C:\\Program Files", paths.resolve_relative_path("A:\\", "C:\\Program Files"));
			end
		end);
		it("resolves relative paths", function ()
			if sep == "/" then
				assert.equal("/run/path", paths.resolve_relative_path("/run", "path"));
			end
		end);
	end)
end)
