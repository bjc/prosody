
local record schema_t
	enum type_e
		"null"
		"boolean"
		"object"
		"array"
		"number"
		"string"
		"integer"
	end

	type : type_e
	enum : { any }
	const : any

	allOf : { schema_t }
	anyOf : { schema_t }
	oneOf : { schema_t }

	["not"] : schema_t
	["if"] : schema_t
	["then"] : schema_t
	["else"] : schema_t

	-- numbers
	multipleOf : number
	maximum : number
	exclusiveMaximum : number
	minimum : number
	exclusiveMinimum : number

	-- strings
	maxLength : number
	minLength : number
	pattern : string
	format : string

	-- arrays
	prefixItems : { schema_t }
	items : schema_t
	contains : schema_t
	maxItems : number
	minItems : number
	uniqueItems : boolean
	maxContains : number
	minContains : number

	-- objects
	properties : { string : schema_t | type_e }
	maxProperties : number
	minProperties : number
	required : { string }
	dependentRequired : { string : { string } }
	additionalProperties: schema_t
	patternProperties: schema_t
	propertyNames : schema_t

	-- xml
	record xml_t
		name : string
		namespace : string
		prefix : string
		attribute : boolean
		wrapped : boolean

		-- nonstantard, maybe in the future
		text : boolean
		x_name_is_value : boolean
		x_single_attribute : string
	end

	xml : xml_t

	-- descriptive
	title : string
	description : string
	deprecated : boolean
	readOnly : boolean
	writeOnly : boolean
end
local type_e = schema_t.type_e

-- TODO validator function per schema property

local type_validators : { type_e : function (schema_t, any) : boolean } = {}

local function simple_validate(schema : type_e, data : any) : boolean
	if schema == "object" and data is table then
		return type(data) == "table" and (next(data)==nil or type((next(data, nil))) == "string")
	elseif schema == "array" and data is table then
		return type(data) == "table" and (next(data)==nil or type((next(data, nil))) == "number")
	elseif schema == "integer" then
		return math.type(data) == schema
	else
		return type(data) == schema
	end
end

type_validators.string = function (schema : schema_t, data : any) : boolean
	-- XXX this is measured in byte, while JSON measures in ... bork
	-- TODO use utf8.len?
	if data is string then
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

type_validators.number = function (schema : schema_t, data : number) : boolean
	if schema.multipleOf and data % schema.multipleOf ~= 0 then
		return false
	end

	if schema.maximum and not ( data <= schema.maximum ) then
		return false
	end

	if schema.exclusiveMaximum and not ( data < schema.exclusiveMaximum ) then
		return false
	end

	if schema.minimum and not ( data >= schema.minimum ) then
		return false
	end

	if schema.exclusiveMinimum and not ( data > schema.exclusiveMinimum ) then
		return false
	end

	return true
end

type_validators.integer = type_validators.number

local function validate(schema : schema_t | type_e | boolean, data : any) : boolean
	if schema is boolean then
		return schema
	end
	if schema is type_e then
		return simple_validate(schema, data)
	end
	if schema is schema_t then
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

		if not simple_validate(schema.type, data) then
			return false
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

		local validator = type_validators[schema.type]
		if not validator then
			return true
		end

		return validator(schema, data)
	end
end

type_validators.table = function (schema : schema_t, data : any) : boolean
	if data is table then

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
			local additional : schema_t | boolean = schema.additionalProperties or true
			for k, v in pairs(data) do
				if schema.propertyNames and not validate(schema.propertyNames, k) then
					return false
				end
				local s = schema.properties[k as string] or additional as schema_t
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
			-- only works for scalars, would need to deep-compare for objects/arrays/tables
			local values : { any : boolean } = {}
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
			for i = p+1, #data do
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

type_validators.object = function (schema : schema_t, data : any) : boolean
	if data is table then
		for k in pairs(data) do
			if not k is string then
				return false
			end
		end

		return type_validators.table(schema, data)
	end
	return false
end

type_validators.array = function (schema : schema_t, data : any) : boolean
	if data is table then

		-- just check that there the keys are all numbers
		for i in pairs(data) do
			if not i is number then
				return false
			end
		end

		return type_validators.table(schema, data)
	end
	return false
end

return {
	validate = validate;
	schema_t = schema_t;
}
