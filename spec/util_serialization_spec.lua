local serialization = require "util.serialization";

describe("util.serialization", function ()
	describe("serialize", function ()
		it("makes a string", function ()
			assert.is_string(serialization.serialize({}));
			assert.is_string(serialization.serialize(nil));
			assert.is_string(serialization.serialize(1));
			assert.is_string(serialization.serialize(true));
			assert.is_string(serialization.serialize(function () end));
		end);

		it("roundtrips", function ()
			local function test(data)
				local serialized = serialization.serialize(data);
				assert.is_string(serialized);
				local deserialized, err = serialization.deserialize(serialized);
				assert.same(data, deserialized, err);
			end

			test({});
			test({hello="world"});
			test("foobar")
			test("\0\1\2\3");
			test("nödåtgärd");
			test({1,2,3,4});
			test({foo={[100]={{"bar"},{baz=1}}}});
		end);
	end);
end);

