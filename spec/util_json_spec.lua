
local json = require "util.json";

describe("util.json", function()
	describe("#encode()", function()
		it("should work", function()
			local function test(f, j, e)
				if e then
					assert.are.equal(f(j), e);
				end
				assert.are.equal(f(j), f(json.decode(f(j))));
			end
			test(json.encode, json.null, "null")
			test(json.encode, {}, "{}")
			test(json.encode, {a=1});
			test(json.encode, {a={1,2,3}});
			test(json.encode, {1}, "[1]");
		end);
	end);

	describe("#decode()", function()
		it("should work", function()
			local empty_array = json.decode("[]");
			assert.are.equal(type(empty_array), "table");
			assert.are.equal(#empty_array, 0);
			assert.are.equal(next(empty_array), nil);
		end);
	end);

	describe("testcases", function()

		local valid_data = {};
		local invalid_data = {};

		local skip = "fail1.json fail9.json fail18.json fail15.json fail13.json fail25.json fail26.json fail27.json fail28.json fail17.json pass1.json";

		setup(function()
			local lfs = require "lfs";
			local path = "spec/json";
			for name in lfs.dir(path) do
				if name:match("%.json$") then
					local f = assert(io.open(path.."/"..name));
					local content = assert(f:read("*a"));
					assert(f:close());
					if skip:find(name) then
						-- Skip
					elseif name:match("^pass") then
						valid_data[name] = content;
					elseif name:match("^fail") then
						invalid_data[name] = content;
					end
				end
			end
		end)

		it("should pass valid testcases", function()
			for name, content in pairs(valid_data) do
				local parsed, err = json.decode(content);
				assert(parsed, name..": "..tostring(err));
			end
		end);

		it("should fail invalid testcases", function()
			for name, content in pairs(invalid_data) do
				local parsed, err = json.decode(content);
				assert(not parsed, name..": "..tostring(err));
			end			
		end);
	end)
end);
