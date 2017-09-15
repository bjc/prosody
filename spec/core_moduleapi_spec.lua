
package.loaded["core.configmanager"] = {};
package.loaded["core.statsmanager"] = {};
package.loaded["net.server"] = {};

local set = require "util.set";

_G.prosody = { hosts = {}, core_post_stanza = true };

local api = require "core.moduleapi";

local module = setmetatable({}, {__index = api});
local opt = nil;
function module:log() end
function module:get_option(name)
	if name == "opt" then
		return opt;
	else
		return nil;
	end
end

function test_option_value(value, returns)
	opt = value;
	assert(module:get_option_number("opt") == returns.number, "number doesn't match");
	assert(module:get_option_string("opt") == returns.string, "string doesn't match");
	assert(module:get_option_boolean("opt") == returns.boolean, "boolean doesn't match");

	if type(returns.array) == "table" then
		local target_array, returned_array = returns.array, module:get_option_array("opt");
		assert(#target_array == #returned_array, "array length doesn't match");
		for i=1,#target_array do
			assert(target_array[i] == returned_array[i], "array item doesn't match");
		end
	else
		assert(module:get_option_array("opt") == returns.array, "array is returned (not nil)");
	end

	if type(returns.set) == "table" then
		local target_items, returned_items = set.new(returns.set), module:get_option_set("opt");
		assert(target_items == returned_items, "set doesn't match");
	else
		assert(module:get_option_set("opt") == returns.set, "set is returned (not nil)");
	end
end

describe("core.moduleapi", function()
	describe("#get_option_*()", function()
		it("should handle missing options", function()
			test_option_value(nil, {});
		end);

		it("should return correctly handle boolean options", function()
			test_option_value(true, { boolean = true, string = "true", array = {true}, set = {true} });
			test_option_value(false, { boolean = false, string = "false", array = {false}, set = {false} });
			test_option_value("true", { boolean = true, string = "true", array = {"true"}, set = {"true"} });
			test_option_value("false", { boolean = false, string = "false", array = {"false"}, set = {"false"} });
			test_option_value(1, { boolean = true, string = "1", array = {1}, set = {1}, number = 1 });
			test_option_value(0, { boolean = false, string = "0", array = {0}, set = {0}, number = 0 });
		end);

		it("should return handle strings", function()
			test_option_value("hello world", { string = "hello world", array = {"hello world"}, set = {"hello world"} });
		end);

		it("should return handle numbers", function()
			test_option_value(1234, { string = "1234", number = 1234, array = {1234}, set = {1234} });
		end);

		it("should return handle arrays", function()
			test_option_value({1, 2, 3}, { boolean = true, string = "1", number = 1, array = {1, 2, 3}, set = {1, 2, 3} });
			test_option_value({1, 2, 3, 3, 4}, {boolean = true, string = "1", number = 1, array = {1, 2, 3, 3, 4}, set = {1, 2, 3, 4} });
			test_option_value({0, 1, 2, 3}, { boolean = false, string = "0", number = 0, array = {0, 1, 2, 3}, set = {0, 1, 2, 3} });	
		end);
	end)
end)
