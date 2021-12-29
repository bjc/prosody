-- Copyright (C) 2021 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- Based on
-- https://json-schema.org/draft/2020-12/json-schema-core.html
-- https://json-schema.org/draft/2020-12/json-schema-validation.html
--

local json = require"util.json"
local null = json.null;

local pointer = require "util.jsonpointer"

local type json_type_name = json.json_type_name

-- json_type_name here is non-standard
local type schema_t = boolean | json_type_name | json_schema_object

local record json_schema_object
	type json_type_name = json.json_type_name
	type schema_object = json_schema_object

	type : json_type_name
	enum : { any }
	const : any

	allOf : { schema_t }
	anyOf : { schema_t }
	oneOf : { schema_t }

	["not"] : schema_t
	["if"] : schema_t
	["then"] : schema_t
	["else"] : schema_t

	["$ref"] : string

	-- numbers
	multipleOf : number
	maximum : number
	exclusiveMaximum : number
	minimum : number
	exclusiveMinimum : number

	-- strings
	maxLength : integer
	minLength : integer
	pattern : string
	format : string

	-- arrays
	prefixItems : { schema_t }
	items : schema_t
	contains : schema_t
	maxItems : integer
	minItems : integer
	uniqueItems : boolean
	maxContains : integer
	minContains : integer

	-- objects
	properties : { string : schema_t }
	maxProperties : integer
	minProperties : integer
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

	-- methods
	validate : function ( schema_t, any, json_schema_object ) : boolean
end

-- TODO validator function per schema property

local type_validators : { json_type_name : function (schema_t, any, json_schema_object) : boolean } = {}

local function simple_validate(schema : json_type_name, data : any) : boolean
	if schema == "object" and data is table then
		return type(data) == "table" and (next(data)==nil or type((next(data, nil))) == "string")
	elseif schema == "array" and data is table then
		return type(data) == "table" and (next(data)==nil or type((next(data, nil))) == "number")
	elseif schema == "integer" then
		return math.type(data) == schema
	elseif schema == "null" then
		return data == null
	else
		return type(data) == schema
	end
end

type_validators.string = function (schema : json_schema_object, data : any) : boolean
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

type_validators.number = function (schema : json_schema_object, data : number) : boolean
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

local function validate(schema : schema_t, data : any, root : json_schema_object) : boolean
	if schema is boolean then
		return schema
	end
	if schema is json_type_name then
		return simple_validate(schema, data)
	end
	if schema is json_schema_object then
		if root == nil then
			root = schema
		end
		if schema["$ref"] and schema["$ref"]:sub(1,1) == "#" then
			local referenced = pointer.resolve(root as table, schema["$ref"]:sub(2)) as schema_t
			if referenced ~= nil then
				return validate(referenced, data, root);
			end
		end

		if schema.allOf then
			for _, sub in ipairs(schema.allOf) do
				if not validate(sub, data, root) then
					return false
				end
			end
			return true
		end

		if schema.oneOf then
			local valid = 0
			for _, sub in ipairs(schema.oneOf) do
				if validate(sub, data, root) then
					valid = valid + 1
				end
			end
			return valid == 1
		end

		if schema.anyOf then
			for _, sub in ipairs(schema.anyOf) do
				if validate(sub, data, root) then
					return true
				end
			end
			return false
		end

		if schema["not"] then
			if validate(schema["not"], data, root) then
				return false
			end
		end

		if schema["if"] then
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
				return validator(schema, data, root)
			end
		end
		return true
	end
end

type_validators.table = function (schema : json_schema_object, data : any, root : json_schema_object) : boolean
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
			local additional : schema_t = schema.additionalProperties or true
			for k, v in pairs(data) do
				if schema.propertyNames and not validate(schema.propertyNames, k, root) then
					return false
				end
				local s = schema.properties[k as string] or additional
				if not validate(s, v, root) then
					return false
				end
			end
		elseif schema.additionalProperties then
			for k, v in pairs(data) do
				if schema.propertyNames and not validate(schema.propertyNames, k, root) then
					return false
				end
				if not validate(schema.additionalProperties, v, root) then
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
				if validate(s, data[i], root) then
					p = i
				else
					return false
				end
			end
		end

		if schema.items then
			for i = p+1, #data do
				if not validate(schema.items, data[i], root) then
					return false
				end
			end
		end

		if schema.contains then
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

		return true
	end
	return false
end

type_validators.object = function (schema : schema_t, data : any, root : json_schema_object) : boolean
	if data is table then
		for k in pairs(data) do
			if not k is string then
				return false
			end
		end

		return type_validators.table(schema, data, root)
	end
	return false
end

type_validators.array = function (schema : schema_t, data : any, root : json_schema_object) : boolean
	if data is table then

		-- just check that there the keys are all numbers
		for i in pairs(data) do
			if not i is number then
				return false
			end
		end

		return type_validators.table(schema, data, root)
	end
	return false
end

json_schema_object.validate = validate;

return json_schema_object;
