local server = require "net.server_select";
package.loaded["net.server"] = server;

local function mock_prosody()
	_G.prosody = {
		core_post_stanza = function () end;
		events = require "util.events".new();
		hosts = {};
		paths = {
			data = "./data";
		};
	};
end

local configs = {
	internal = {
		storage = "internal";
	};
	sqlite = {
		storage = "sql";
		sql = { driver = "SQLite3", database = "prosody-tests.sqlite" };
	};
	mysql = {
		storage = "sql";
		sql = { driver = "MySQL",  database = "prosody", username = "prosody", password = "secret", host = "localhost" };
	};
	postgres = {
		storage = "sql";
		sql = { driver = "PostgreSQL", database = "prosody", username = "prosody", password = "secret", host = "localhost" };
	};
};

local test_host = "storage-unit-tests.invalid";

describe("storagemanager", function ()
	for backend, backend_config in pairs(configs) do
		local tagged_name = "#"..backend;
		if backend ~= backend_config.storage then
			tagged_name = tagged_name.." #"..backend_config.storage;
		end
		insulate(tagged_name.." #storage backend", function ()
			mock_prosody();

			local config = require "core.configmanager";
			local sm = require "core.storagemanager";
			local hm = require "core.hostmanager";
			local mm = require "core.modulemanager";

			-- Simple check to ensure insulation is working correctly
			assert.is_nil(config.get(test_host, "storage"));

			for k, v in pairs(backend_config) do
				config.set(test_host, k, v);
			end
			assert(hm.activate(test_host, {}));
			sm.initialize_host(test_host);
			assert(mm.load(test_host, "storage_"..backend_config.storage));

			-- These tests rely on being executed in order, disable any order
			-- randomization for this block
			randomize(false);

			local store;
			it("may open a store", function ()
				store = assert(sm.open(test_host, "test"));
			end);

			local simple_data = { foo = "bar" };

			it("may set data for a user", function ()
				assert(store:set("user9999", simple_data));
			end);

			it("may get data for a user", function ()
				assert.same(simple_data, assert(store:get("user9999")));
			end);

			it("may remove data for a user", function ()
				assert(store:set("user9999", nil));
				local ret, err = store:get("user9999");
				assert.is_nil(ret);
				assert.is_nil(err);
			end);
		end);
	end
end);
