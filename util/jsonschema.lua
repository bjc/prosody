local json = require("util.json")
local null = json.null;

local json_type_name = json.json_type_name

local schema_t = {}

local json_schema_object = {xml_t = {}}

local type_validators = {}

local function simple_validate(schema, data)
	if schema == "object" and type(data) == "table" then
		return type(data) == "table" and (next(data) == nil or type((next(data, nil))) == "string")
	elseif schema == "array" and type(data) == "table" then
		return type(data) == "table" and (next(data) == nil or type((next(data, nil))) == "number")
	elseif schema == "integer" then
		return math.type(data) == schema
	elseif schema == "null" then
		return data == null
	else
		return type(data) == schema
	end
end

type_validators.string = function(schema, data)

	if type(data) == "string" then
		if schema.maxLength and #data > schema.maxLength then
			return false
		end
		if schema.minLength and #data < schema.minLength then
			return false
		end
		return true
	end
	return false
end

type_validators.number = function(schema, data)
	if schema.multipleOf and data % schema.multipleOf ~= 0 then
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

	return true
end

type_validators.integer = type_validators.number

local function validate(schema, data)
	if type(schema) == "boolean" then
		return schema
	end
	if type(schema) == "string" then
		return simple_validate(schema, data)
	end
	if type(schema) == "table" then
		if schema.allOf then
			for _, sub in ipairs(schema.allOf) do
				if not validate(sub, data) then
					return false
				end
			end
			return true
		end

		if schema.oneOf then
			local valid = 0
			for _, sub in ipairs(schema.oneOf) do
				if validate(sub, data) then
					valid = valid + 1
				end
			end
			return valid == 1
		end

		if schema.anyOf then
			for _, sub in ipairs(schema.anyOf) do
				if validate(sub, data) then
					return true
				end
			end
			return false
		end

		if schema["not"] then
			if validate(schema["not"], data) then
				return false
			end
		end

		if schema["if"] then
			if validate(schema["if"], data) then
				if schema["then"] then
					return validate(schema["then"], data)
				end
			else
				if schema["else"] then
					return validate(schema["else"], data)
				end
			end
		end

		if schema.const ~= nil and schema.const ~= data then
			return false
		end

		if schema["enum"] ~= nil then
			for _, v in ipairs(schema["enum"]) do
				if v == data then
					return true
				end
			end
			return false
		end

		if schema.type then
			if not simple_validate(schema.type, data) then
				return false
			end

			local validator = type_validators[schema.type]
			if validator then
				return validator(schema, data)
			end
		end
		return true
	end
end

type_validators.table = function(schema, data)
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

		if schema.properties then
			local additional = schema.additionalProperties or true
			for k, v in pairs(data) do
				if schema.propertyNames and not validate(schema.propertyNames, k) then
					return false
				end
				local s = schema.properties[k] or additional
				if not validate(s, v) then
					return false
				end
			end
		elseif schema.additionalProperties then
			for k, v in pairs(data) do
				if schema.propertyNames and not validate(schema.propertyNames, k) then
					return false
				end
				if not validate(schema.additionalProperties, v) then
					return false
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
		if schema.prefixItems then
			for i, s in ipairs(schema.prefixItems) do
				if validate(s, data[i]) then
					p = i
				else
					return false
				end
			end
		end

		if schema.items then
			for i = p + 1, #data do
				if not validate(schema.items, data[i]) then
					return false
				end
			end
		end

		if schema.contains then
			local found = false
			for i = 1, #data do
				if validate(schema.contains, data[i]) then
					found = true
					break
				end
			end
			if not found then
				return false
			end
		end

		return true
	end
	return false
end

type_validators.object = function(schema, data)
	if type(data) == "table" then
		for k in pairs(data) do
			if not (type(k) == "string") then
				return false
			end
		end

		return type_validators.table(schema, data)
	end
	return false
end

type_validators.array = function(schema, data)
	if type(data) == "table" then

		for i in pairs(data) do
			if not (type(i) == "number") then
				return false
			end
		end

		return type_validators.table(schema, data)
	end
	return false
end

json_schema_object.validate = validate;

return json_schema_object
