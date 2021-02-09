describe("util.datamanager", function()
	local dm;
	setup(function()
		dm = require "util.datamanager";
		dm.set_data_path("./data");
	end);

	describe("keyvalue", function()
		local data = {hello = "world"};

		do
			local ok, err = dm.store("keyval-user", "datamanager.test", "testdata", data);
			assert.truthy(ok, err);
		end

		do
			local read, err = dm.load("keyval-user", "datamanager.test", "testdata")
			assert.same(data, read, err);
		end

		do
			local ok, err = dm.store("keyval-user", "datamanager.test", "testdata", nil);
			assert.truthy(ok, err);
		end

		do
			local read, err = dm.load("keyval-user", "datamanager.test", "testdata")
			assert.is_nil(read, err);
		end
	end)

	describe("lists", function()
		do
			local ok, err = dm.list_store("list-user", "datamanager.test", "testdata", {});
			assert.truthy(ok, err);
		end

		do
			local nothing, err = dm.list_load("list-user", "datamanager.test", "testdata");
			assert.is_nil(nothing, err);
			assert.is_nil(err);
		end

		do
			local ok, err = dm.list_append("list-user", "datamanager.test", "testdata", {id = 1});
			assert.truthy(ok, err);
		end

		do
			local ok, err = dm.list_append("list-user", "datamanager.test", "testdata", {id = 2});
			assert.truthy(ok, err);
		end

		do
			local ok, err = dm.list_append("list-user", "datamanager.test", "testdata", {id = 3});
			assert.truthy(ok, err);
		end

		do
			local list, err = dm.list_load("list-user", "datamanager.test", "testdata");
			assert.same(list, {{id = 1}; {id = 2}; {id = 3}}, err);
		end

		do
			local ok, err = dm.list_store("list-user", "datamanager.test", "testdata", {});
			assert.truthy(ok, err);
		end

		do
			local nothing, err = dm.list_load("list-user", "datamanager.test", "testdata");
			assert.is_nil(nothing, err);
			assert.is_nil(err);
		end

	end)
end)
