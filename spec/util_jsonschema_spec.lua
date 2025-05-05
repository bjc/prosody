local js = require "util.jsonschema";
local json = require "util.json";
local lfs = require "lfs";

-- https://github.com/json-schema-org/JSON-Schema-Test-Suite.git 2.0.0-755-g7950d9e
local test_suite_dir = "spec/JSON-Schema-Test-Suite/tests/draft2020-12"
if lfs.attributes(test_suite_dir, "mode") ~= "directory" then return end

-- Tests to skip and short reason why (NYI = not yet implemented)
local skip = {
	["additionalProperties.json:0:2"] = "distinguishing objects from arrays",
	["additionalProperties.json:0:5"] = "NYI",
	["additionalProperties.json:1:0"] = "NYI",
	["anchor.json"] = "$anchor NYI",
	["const.json:1"] = "deepcompare",
	["const.json:2"] = "deepcompare",
	["const.json:8"] = "deepcompare",
	["const.json:9"] = "deepcompare",
	["contains.json:0:5"] = "distinguishing objects from arrays",
	["defs.json"] = "need built-in meta-schema",
	["dependentSchemas.json:2:2"] = "NYI", -- minProperties
	["dynamicRef.json"] = "NYI",
	["enum.json:1:3"] = "deepcompare",
	["id.json"] = "NYI",
	["maxProperties.json"] = "NYI",
	["minProperties.json"] = "NYI",
	["multipleOf.json:1"] = "multiples of IEEE 754 fractions",
	["multipleOf.json:2"] = "multiples of IEEE 754 fractions",
	["multipleOf.json:4"] = "multiples of IEEE 754 fractions",
	["pattern.json"] = "NYI",
	["patternProperties.json"] = "NYI",
	["properties.json:1:2"] = "NYI",
	["properties.json:1:3"] = "NYI",
	["propertyNames.json:1:1"] = "NYI",
	["ref.json:0:3"] = "util.jsonpointer recursive issue?",
	["ref.json:3:2"] = "FIXME investigate, util.jsonpath issue?",
	["ref.json:6:1"] = "NYI",
	["ref.json:11"] = "NYI",
	["ref.json:12:1"] = "FIXME",
	["ref.json:13"] = "NYI",
	["ref.json:14"] = "NYI",
	["ref.json:15"] = "NYI",
	["ref.json:16"] = "NYI",
	["ref.json:17"] = "NYI",
	["ref.json:18"] = "NYI",
	["ref.json:19"] = "NYI",
	["ref.json:20"] = "NYI",
	["ref.json:25"] = "NYI",
	["ref.json:26"] = "NYI",
	["ref.json:27"] = "NYI",
	["ref.json:28"] = "NYI",
	["ref.json:29"] = "NYI",
	["ref.json:30"] = "NYI",
	["ref.json:31"] = "NYI",
	["ref.json:32"] = "NYI",
	["not.json:6"] = "NYI",
	["required.json:0:2"] = "distinguishing objects from arrays",
	["required.json:4"] = "JavaScript specific and distinguishing objects from arrays",
	["not.json:8:0"] = "NYI",
	["refRemote.json"] = "DEFINITELY NYI",
	["type.json:0:1"] = "1.0 is not an integer!",
	["type.json:3:4"] = "distinguishing objects from arrays",
	["type.json:3:6"] = "null is weird",
	["type.json:4:3"] = "distinguishing objects from arrays",
	["type.json:4:6"] = "null is weird",
	["type.json:9:4"] = "null is weird",
	["unevaluatedItems.json"] = "NYI",
	["unevaluatedProperties.json"] = "NYI",
	["uniqueItems.json:0:10"] = "deepcompare",
	["uniqueItems.json:0:12"] = "deepcompare",
	["uniqueItems.json:0:14"] = "deepcompare",
	["uniqueItems.json:0:15"] = "deepcompare",
	["uniqueItems.json:0:23"] = "deepcompare",
	["uniqueItems.json:0:25"] = "deepcompare",
	["uniqueItems.json:0:9"] = "deepcompare",
	["unknownKeyword.json"] = "NYI",
	["vocabulary.json"] = "NYI",
};

local function label(s, i)
	return string.format("%s:%d", s, i-1);
end

describe("util.jsonschema.validate", function()
	for test_case_file in lfs.dir(test_suite_dir) do
		-- print(skip[test_case_file] and "do  " or "skip", test_case_file)
		if test_case_file:sub(-5) == ".json" and not skip[test_case_file] then
			describe(test_case_file, function()
				local test_cases;
				setup(function()
					local f = assert(io.open(test_suite_dir .. "/" .. test_case_file));
					local rawdata = assert(f:read("*a"), "failed to read " .. test_case_file)
					test_cases = assert(json.decode(rawdata), "failed to parse " .. test_case_file)
				end)
				describe("tests", function()
					for i, schema_test in ipairs(test_cases) do
						local generic_label = label(test_case_file, i);
						describe(schema_test.description or generic_label, function()
							for j, test in ipairs(schema_test.tests) do
								local specific_label = label(generic_label, j);
								((skip[generic_label] or skip[specific_label]) and pending or it)(test.description, function()
									assert.equal(test.valid, js.validate(schema_test.schema, test.data), specific_label .. " " .. test.description);
								end)
							end
						end)
					end
				end)
			end)
		end
	end
end);
