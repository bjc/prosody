
local configmanager = require "core.configmanager";

describe("core.configmanager", function()
	describe("#get()", function()
		it("should work", function()
			configmanager.set("example.com", "testkey", 123);
			assert.are.equal(configmanager.get("example.com", "testkey"), 123, "Retrieving a set key");

			configmanager.set("*", "testkey1", 321);
			assert.are.equal(configmanager.get("*", "testkey1"), 321, "Retrieving a set global key");
			assert.are.equal(configmanager.get("example.com", "testkey1"), 321, "Retrieving a set key of undefined host, of which only a globally set one exists");

			configmanager.set("example.com", ""); -- Creates example.com host in config
			assert.are.equal(configmanager.get("example.com", "testkey1"), 321, "Retrieving a set key, of which only a globally set one exists");

			assert.are.equal(configmanager.get(), nil, "No parameters to get()");
			assert.are.equal(configmanager.get("undefined host"), nil, "Getting for undefined host");
			assert.are.equal(configmanager.get("undefined host", "undefined key"), nil, "Getting for undefined host & key");
		end);
	end);

	describe("#set()", function()
		it("should work", function()
			assert.are.equal(configmanager.set("*"), false, "Set with no key");

			assert.are.equal(configmanager.set("*", "set_test", "testkey"), true, "Setting a nil global value");
			assert.are.equal(configmanager.set("*", "set_test", "testkey", 123), true, "Setting a global value");
		end);
	end);
end);
