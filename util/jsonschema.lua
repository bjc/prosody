-- This file is generated from teal-src/util/jsonschema.lua

if not math.type then
	require("prosody.util.mathcompat")
end

local utf8_len = rawget(_G, "utf8") and utf8.len or require("prosody.util.encodings").utf8.length;

local json = require("prosody.util.json")
local null = json.null;

local pointer = require("prosody.util.jsonpointer")

local json_schema_object = { xml_t = {} }

local function simple_validate(schema, data)
	if schema == nil then
		return true
	elseif schema == "object" and type(data) == "table" then
		return type(data) == "table" and (next(data) == nil or type((next(data, nil))) == "string")
	elseif schema == "array" and type(data) == "table" then
		return type(data) == "table" and (next(data) == nil or type((next(data, nil))) == "number")
	elseif schema == "integer" then
		return math.type(data) == schema
	elseif schema == "null" then
		return data == null
	elseif type(schema) == "table" then
		for _, one in ipairs(schema) do
			if simple_validate(one, data) then
				return true
			end
		end
		return false
	else
		return type(data) == schema
	end
end

local function mkerr(sloc, iloc, err)
	return { schemaLocation = sloc; instanceLocation = iloc; error = err }
end

local function validate(schema, data, root, sloc, iloc, errs)
	if type(schema) == "boolean" then
		return schema
	end

	if root == nil then
		root = schema
		iloc = ""
		sloc = ""
		errs = {};
	end

	if schema["$ref"] and schema["$ref"]:sub(1, 1) == "#" then
		local referenced = pointer.resolve(root, schema["$ref"]:sub(2))
		if referenced ~= nil and referenced ~= root and referenced ~= schema then
			if not validate(referenced, data, root, schema["$ref"], iloc, errs) then
				table.insert(errs, mkerr(sloc .. "/$ref", iloc, "Subschema failed validation"))
				return false, errs
			end
		end
	end

	if not simple_validate(schema.type, data) then
		table.insert(errs, mkerr(sloc .. "/type", iloc, "unexpected type"));
		return false, errs
	end

	if schema.type == "object" then
		if type(data) == "table" then

			for k in pairs(data) do
				if not (type(k) == "string") then
					table.insert(errs, mkerr(sloc .. "/type", iloc, "'object' had non-string keys"));
					return false, errs
				end
			end
		end
	end

	if schema.type == "array" then
		if type(data) == "table" then

			for i in pairs(data) do
				if not (math.type(i) == "integer") then
					table.insert(errs, mkerr(sloc .. "/type", iloc, "'array' had non-integer keys"));
					return false, errs
				end
			end
		end
	end

	if schema["enum"] ~= nil then
		local match = false
		for _, v in ipairs(schema["enum"]) do
			if v == data then

				match = true
				break
			end
		end
		if not match then
			table.insert(errs, mkerr(sloc .. "/enum", iloc, "not one of the enumerated values"));
			return false, errs
		end
	end

	if type(data) == "string" then
		if schema.maxLength and utf8_len(data) > schema.maxLength then
			table.insert(errs, mkerr(sloc .. "/maxLength", iloc, "string too long"))
			return false, errs
		end
		if schema.minLength and utf8_len(data) < schema.minLength then
			table.insert(errs, mkerr(sloc .. "/maxLength", iloc, "string too short"))
			return false, errs
		end
		if schema.luaPattern and not data:match(schema.luaPattern) then
			table.insert(errs, mkerr(sloc .. "/luaPattern", iloc, "string does not match pattern"))
			return false, errs
		end
	end

	if type(data) == "number" then
		if schema.multipleOf and (data == 0 or data % schema.multipleOf ~= 0) then
			table.insert(errs, mkerr(sloc .. "/luaPattern", iloc, "not a multiple"))
			return false, errs
		end

		if schema.maximum and not (data <= schema.maximum) then
			table.insert(errs, mkerr(sloc .. "/maximum", iloc, "number exceeds maximum"))
			return false, errs
		end

		if schema.exclusiveMaximum and not (data < schema.exclusiveMaximum) then
			table.insert(errs, mkerr(sloc .. "/exclusiveMaximum", iloc, "number exceeds exclusive maximum"))
			return false, errs
		end

		if schema.minimum and not (data >= schema.minimum) then
			table.insert(errs, mkerr(sloc .. "/minimum", iloc, "number below minimum"))
			return false, errs
		end

		if schema.exclusiveMinimum and not (data > schema.exclusiveMinimum) then
			table.insert(errs, mkerr(sloc .. "/exclusiveMinimum", iloc, "number below exclusive minimum"))
			return false, errs
		end
	end

	if schema.allOf then
		for i, sub in ipairs(schema.allOf) do
			if not validate(sub, data, root, sloc .. "/allOf/" .. i, iloc, errs) then
				table.insert(errs, mkerr(sloc .. "/allOf", iloc, "did not match all subschemas"))
				return false, errs
			end
		end
	end

	if schema.oneOf then
		local valid = 0
		for i, sub in ipairs(schema.oneOf) do
			if validate(sub, data, root, sloc .. "/oneOf" .. i, iloc, errs) then
				valid = valid + 1
			end
		end
		if valid ~= 1 then
			table.insert(errs, mkerr(sloc .. "/oneOf", iloc, "did not match exactly one subschema"))
			return false, errs
		end
	end

	if schema.anyOf then
		local match = false
		for i, sub in ipairs(schema.anyOf) do
			if validate(sub, data, root, sloc .. "/anyOf/" .. i, iloc, errs) then
				match = true
				break
			end
		end
		if not match then
			table.insert(errs, mkerr(sloc .. "/anyOf", iloc, "did not match any subschema"))
			return false, errs
		end
	end

	if schema["not"] ~= nil then
		if validate(schema["not"], data, root, sloc .. "/not", iloc, errs) then
			table.insert(errs, mkerr(sloc .. "/not", iloc, "did match subschema"))
			return false, errs
		end
	end

	if schema["if"] ~= nil then
		if validate(schema["if"], data, root, sloc .. "/if", iloc, errs) then
			if schema["then"] ~= nil then
				if not validate(schema["then"], data, root, sloc .. "/then", iloc, errs) then
					table.insert(errs, mkerr(sloc .. "/then", iloc, "did not match subschema"))
					return false, errs
				end
			end
		else
			if schema["else"] ~= nil then
				if not validate(schema["else"], data, root, sloc .. "/else", iloc, errs) then
					table.insert(errs, mkerr(sloc .. "/else", iloc, "did not match subschema"))
					return false, errs
				end
			end
		end
	end

	if schema.const ~= nil and schema.const ~= data then
		table.insert(errs, mkerr(sloc .. "/const", iloc, "did not match constant value"))
		return false, errs
	end

	if type(data) == "table" then

		if schema.maxItems and #(data) > schema.maxItems then
			table.insert(errs, mkerr(sloc .. "/maxItems", iloc, "too many items"))
			return false, errs
		end

		if schema.minItems and #(data) < schema.minItems then
			table.insert(errs, mkerr(sloc .. "/minItems", iloc, "too few items"))
			return false, errs
		end

		if schema.required then
			for _, k in ipairs(schema.required) do
				if data[k] == nil then
					table.insert(errs, mkerr(sloc .. "/required", iloc .. "/" .. tostring(k), "missing required property"))
					return false, errs
				end
			end
		end

		if schema.dependentRequired then
			for k, reqs in pairs(schema.dependentRequired) do
				if data[k] ~= nil then
					for _, req in ipairs(reqs) do
						if data[req] == nil then
							table.insert(errs, mkerr(sloc .. "/dependentRequired", iloc, "missing dependent required property"))
							return false, errs
						end
					end
				end
			end
		end

		if schema.propertyNames ~= nil then

			for k in pairs(data) do
				if not validate(schema.propertyNames, k, root, sloc .. "/propertyNames", iloc .. "/" .. tostring(k), errs) then
					table.insert(errs, mkerr(sloc .. "/propertyNames", iloc .. "/" .. tostring(k), "a property name did not match subschema"))
					return false, errs
				end
			end
		end

		local seen_properties = {}

		if schema.properties then
			for k, sub in pairs(schema.properties) do
				if data[k] ~= nil and not validate(sub, data[k], root, sloc .. "/" .. tostring(k), iloc .. "/" .. tostring(k), errs) then
					table.insert(errs, mkerr(sloc .. "/" .. tostring(k), iloc .. "/" .. tostring(k), "a property did not match subschema"))
					return false, errs
				end
				seen_properties[k] = true
			end
		end

		if schema.luaPatternProperties then

			for pattern, sub in pairs(schema.luaPatternProperties) do
				for k in pairs(data) do
					if type(k) == "string" and k:match(pattern) then
						if not validate(sub, data[k], root, sloc .. "/luaPatternProperties", iloc, errs) then
							table.insert(errs, mkerr(sloc .. "/luaPatternProperties/" .. pattern, iloc .. "/" .. tostring(k), "a property did not match subschema"))
							return false, errs
						end
						seen_properties[k] = true
					end
				end
			end
		end

		if schema.additionalProperties ~= nil then
			for k, v in pairs(data) do
				if not seen_properties[k] then
					if not validate(schema.additionalProperties, v, root, sloc .. "/additionalProperties", iloc .. "/" .. tostring(k), errs) then
						table.insert(errs, mkerr(sloc .. "/additionalProperties", iloc .. "/" .. tostring(k), "additional property did not match subschema"))
						return false, errs
					end
				end
			end
		end

		if schema.dependentSchemas then
			for k, sub in pairs(schema.dependentSchemas) do
				if data[k] ~= nil and not validate(sub, data, root, sloc .. "/dependentSchemas/" .. k, iloc, errs) then
					table.insert(errs, mkerr(sloc .. "/dependentSchemas", iloc .. "/" .. tostring(k), "did not match dependent subschema"))
					return false, errs
				end
			end
		end

		if schema.uniqueItems then

			local values = {}
			for _, v in pairs(data) do
				if values[v] then
					table.insert(errs, mkerr(sloc .. "/uniqueItems", iloc, "had duplicate items"))
					return false, errs
				end
				values[v] = true
			end
		end

		local p = 0
		if schema.prefixItems ~= nil then
			for i, s in ipairs(schema.prefixItems) do
				if data[i] == nil then
					break
				elseif validate(s, data[i], root, sloc .. "/prefixItems/" .. i, iloc .. "/" .. i, errs) then
					p = i
				else
					table.insert(errs, mkerr(sloc .. "/prefixItems/" .. i, iloc .. "/" .. tostring(i), "did not match subschema"))
					return false, errs
				end
			end
		end

		if schema.items ~= nil then
			for i = p + 1, #(data) do
				if not validate(schema.items, data[i], root, sloc, iloc .. "/" .. i, errs) then
					table.insert(errs, mkerr(sloc .. "/prefixItems/" .. i, iloc .. "/" .. i, "did not match subschema"))
					return false, errs
				end
			end
		end

		if schema.contains ~= nil then
			local found = 0
			for i = 1, #(data) do
				if validate(schema.contains, data[i], root, sloc .. "/contains", iloc .. "/" .. i, errs) then
					found = found + 1
				else
					table.insert(errs, mkerr(sloc .. "/contains", iloc .. "/" .. i, "did not match subschema"))
				end
			end
			if found < (schema.minContains or 1) then
				table.insert(errs, mkerr(sloc .. "/minContains", iloc, "too few matches"))
				return false, errs
			elseif found > (schema.maxContains or math.huge) then
				table.insert(errs, mkerr(sloc .. "/maxContains", iloc, "too many matches"))
				return false, errs
			end
		end
	end

	return true
end

json_schema_object.validate = validate;

return json_schema_object
