
local configmanager = require "core.configmanager";

describe("core.configmanager", function()
	describe("#get()", function()
		it("should work", function()
			configmanager.set("example.com", "testkey", 123);
			assert.are.equal(123, configmanager.get("example.com", "testkey"), "Retrieving a set key");

			configmanager.set("*", "testkey1", 321);
			assert.are.equal(321, configmanager.get("*", "testkey1"), "Retrieving a set global key");
			assert.are.equal(321, configmanager.get("example.com", "testkey1"),
				"Retrieving a set key of undefined host, of which only a globally set one exists"
			);

			configmanager.set("example.com", ""); -- Creates example.com host in config
			assert.are.equal(321, configmanager.get("example.com", "testkey1"), "Retrieving a set key, of which only a globally set one exists");

			assert.are.equal(nil, configmanager.get(), "No parameters to get()");
			assert.are.equal(nil, configmanager.get("undefined host"), "Getting for undefined host");
			assert.are.equal(nil, configmanager.get("undefined host", "undefined key"), "Getting for undefined host & key");
		end);
	end);

	describe("#set()", function()
		it("should work", function()
			assert.are.equal(false, configmanager.set("*"), "Set with no key");

			assert.are.equal(true, configmanager.set("*", "set_test", "testkey"), "Setting a nil global value");
			assert.are.equal(true, configmanager.set("*", "set_test", "testkey", 123), "Setting a global value");
		end);
	end);
end);
