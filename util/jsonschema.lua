-- This file is generated from teal-src/util/jsonschema.lua

local m_type = function(n)
	return type(n) == "number" and n % 1 == 0 and n <= 9007199254740992 and n >= -9007199254740992 and "integer" or "float";
end;
local json = require("prosody.util.json")
local null = json.null;

local pointer = require("prosody.util.jsonpointer")

local json_type_name = json.json_type_name

local schema_t = {}

local json_schema_object = { xml_t = {} }

local function simple_validate(schema, data)
	if schema == nil then
		return true
	elseif schema == "object" and type(data) == "table" then
		return type(data) == "table" and (next(data) == nil or type((next(data, nil))) == "string")
	elseif schema == "array" and type(data) == "table" then
		return type(data) == "table" and (next(data) == nil or type((next(data, nil))) == "number")
	elseif schema == "integer" then
		return m_type(data) == schema
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

local complex_validate

local function validate(schema, data, root)
	if type(schema) == "boolean" then
		return schema
	else
		return complex_validate(schema, data, root)
	end
end

function complex_validate(schema, data, root)

	if root == nil then
		root = schema
	end

	if schema["$ref"] and schema["$ref"]:sub(1, 1) == "#" then
		local referenced = pointer.resolve(root, schema["$ref"]:sub(2))
		if referenced ~= nil and referenced ~= root and referenced ~= schema then
			if not validate(referenced, data, root) then
				return false
			end
		end
	end

	if not simple_validate(schema.type, data) then
		return false
	end

	if schema.type == "object" then
		if type(data) == "table" then

			for k in pairs(data) do
				if not (type(k) == "string") then
					return false
				end
			end
		end
	end

	if schema.type == "array" then
		if type(data) == "table" then

			for i in pairs(data) do
				if not (m_type(i) == "integer") then
					return false
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
			return false
		end
	end

	if type(data) == "string" then
		if schema.maxLength and #data > schema.maxLength then
			return false
		end
		if schema.minLength and #data < schema.minLength then
			return false
		end
	end

	if type(data) == "number" then
		if schema.multipleOf and (data == 0 or data % schema.multipleOf ~= 0) then
			return false
		end

		if schema.maximum and not (data <= schema.maximum) then
			return false
		end

		if schema.exclusiveMaximum and not (data < schema.exclusiveMaximum) then
			return false
		end

		if schema.minimum and not (data >= schema.minimum) then
			return false
		end

		if schema.exclusiveMinimum and not (data > schema.exclusiveMinimum) then
			return false
		end
	end

	if schema.allOf then
		for _, sub in ipairs(schema.allOf) do
			if not validate(sub, data, root) then
				return false
			end
		end
	end

	if schema.oneOf then
		local valid = 0
		for _, sub in ipairs(schema.oneOf) do
			if validate(sub, data, root) then
				valid = valid + 1
			end
		end
		if valid ~= 1 then
			return false
		end
	end

	if schema.anyOf then
		local match = false
		for _, sub in ipairs(schema.anyOf) do
			if validate(sub, data, root) then
				match = true
				break
			end
		end
		if not match then
			return false
		end
	end

	if schema["not"] then
		if validate(schema["not"], data, root) then
			return false
		end
	end

	if schema["if"] ~= nil then
		if validate(schema["if"], data, root) then
			if schema["then"] then
				return validate(schema["then"], data, root)
			end
		else
			if schema["else"] then
				return validate(schema["else"], data, root)
			end
		end
	end

	if schema.const ~= nil and schema.const ~= data then
		return false
	end

	if type(data) == "table" then

		if schema.maxItems and #data > schema.maxItems then
			return false
		end

		if schema.minItems and #data < schema.minItems then
			return false
		end

		if schema.required then
			for _, k in ipairs(schema.required) do
				if data[k] == nil then
					return false
				end
			end
		end

		if schema.dependentRequired then
			for k, reqs in pairs(schema.dependentRequired) do
				if data[k] ~= nil then
					for _, req in ipairs(reqs) do
						if data[req] == nil then
							return false
						end
					end
				end
			end
		end

		if schema.propertyNames ~= nil then
			for k in pairs(data) do
				if not validate(schema.propertyNames, k, root) then
					return false
				end
			end
		end

		if schema.properties then
			for k, sub in pairs(schema.properties) do
				if data[k] ~= nil and not validate(sub, data[k], root) then
					return false
				end
			end
		end

		if schema.additionalProperties ~= nil then
			for k, v in pairs(data) do
				if schema.properties == nil or schema.properties[k] == nil then
					if not validate(schema.additionalProperties, v, root) then
						return false
					end
				end
			end
		end

		if schema.uniqueItems then

			local values = {}
			for _, v in pairs(data) do
				if values[v] then
					return false
				end
				values[v] = true
			end
		end

		local p = 0
		if schema.prefixItems ~= nil then
			for i, s in ipairs(schema.prefixItems) do
				if data[i] == nil then
					break
				elseif validate(s, data[i], root) then
					p = i
				else
					return false
				end
			end
		end

		if schema.items ~= nil then
			for i = p + 1, #data do
				if not validate(schema.items, data[i], root) then
					return false
				end
			end
		end

		if schema.contains ~= nil then
			local found = false
			for i = 1, #data do
				if validate(schema.contains, data[i], root) then
					found = true
					break
				end
			end
			if not found then
				return false
			end
		end
	end

	return true
end

json_schema_object.validate = validate;

return json_schema_object
