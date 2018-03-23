describe("net.http.server", function ()
	package.loaded["net.server"] = {}
	local server = require "net.http.server";
	describe("events", function ()
		it("should work with util.helpers", function ()
			-- See #1044
			server.add_handler("GET host/foo/*", function () end, 0);
			server.add_handler("GET host/foo/bar", function () end, 0);
			local helpers = require "util.helpers";
			assert.is.string(helpers.show_events(server._events));
		end);
	end);
end);
