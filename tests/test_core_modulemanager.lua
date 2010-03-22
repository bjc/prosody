-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local config = require "core.configmanager";
local helpers = require "util.helpers";
local set = require "util.set";

function load_modules_for_host(load_modules_for_host, mm)
	local test_num = 0;
	local function test_load(global_modules_enabled, global_modules_disabled, host_modules_enabled, host_modules_disabled, expected_modules)
		test_num = test_num + 1;
		-- Prepare
		hosts = { ["example.com"] = {} };
		config.set("*", "core", "modules_enabled", global_modules_enabled);
		config.set("*", "core", "modules_disabled", global_modules_disabled);
		config.set("example.com", "core", "modules_enabled", host_modules_enabled);
		config.set("example.com", "core", "modules_disabled", host_modules_disabled);
		
		expected_modules = set.new(expected_modules);
		expected_modules:add_list(helpers.get_upvalue(load_modules_for_host, "autoload_modules"));
		
		local loaded_modules = set.new();
		function mm.load(host, module)
			assert_equal(host, "example.com", test_num..": Host isn't example.com but "..tostring(host));
			assert_equal(expected_modules:contains(module), true, test_num..": Loading unexpected module '"..tostring(module).."'");
			loaded_modules:add(module);
		end
		load_modules_for_host("example.com");
		assert_equal((expected_modules - loaded_modules):empty(), true, test_num..": Not all modules loaded: "..tostring(expected_modules - loaded_modules));
	end
	
	test_load({ "one", "two", "three" }, nil, nil, nil, { "one", "two", "three" });
	test_load({ "one", "two", "three" }, {}, nil, nil, { "one", "two", "three" });
	test_load({ "one", "two", "three" }, { "two" }, nil, nil, { "one", "three" });
	test_load({ "one", "two", "three" }, { "three" }, nil, nil, { "one", "two" });
	test_load({ "one", "two", "three" }, nil, nil, { "three" }, { "one", "two" });
	test_load({ "one", "two", "three" }, nil, { "three" }, { "three" }, { "one", "two", "three" });

	test_load({ "one", "two" }, nil, { "three" }, nil, { "one", "two", "three" });
	test_load({ "one", "two", "three" }, nil, { "three" }, nil, { "one", "two", "three" });
	test_load({ "one", "two", "three" }, { "three" }, { "three" }, nil, { "one", "two", "three" });
	test_load({ "one", "two" }, { "three" }, { "three" }, nil, { "one", "two", "three" });
end
