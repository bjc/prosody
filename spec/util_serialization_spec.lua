local serialization = require "util.serialization";

describe("util.serialization", function ()
	describe("serialize", function ()
		it("makes a string", function ()
			assert.is_string(serialization.serialize({}));
			assert.is_string(serialization.serialize(nil));
			assert.is_string(serialization.serialize(1));
			assert.is_string(serialization.serialize(true));
		end);

		it("rejects function by default", function ()
			assert.has_error(function ()
				serialization.serialize(function () end)
			end);
		end);

		it("makes a string in debug mode", function ()
			assert.is_string(serialization.serialize(function () end, "debug"));
		end);

		it("rejects cycles", function ()
			assert.has_error(function ()
				local t = {}
				t[t] = { t };
				serialization.serialize(t)
			end);
		end);

		it("rejects multiple references to same table", function ()
			assert.has_error(function ()
				local t1 = {};
				local t2 = { t1, t1 };
				serialization.serialize(t2);
			end);
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
			test({["goto"] = {["function"]={["do"]="keywords"}}});
		end);

		it("can serialize with metatables", function ()
			local s = serialization.new({ freeze = true });
			local t = setmetatable({ a = "hi" }, { __freeze = function (t) return { t.a } end });
			local rt = serialization.deserialize(s(t));
			assert.same({"hi"}, rt);
		end);

	end);
end);

