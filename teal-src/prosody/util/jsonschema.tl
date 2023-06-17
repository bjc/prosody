-- Copyright (C) Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- Based on
-- https://json-schema.org/draft/2020-12/json-schema-core.html
-- https://json-schema.org/draft/2020-12/json-schema-validation.html
--

if not math.type then require "prosody.util.mathcompat" end


local utf8_enc = rawget(_G, "utf8") or require"prosody.util.encodings".utf8;
local utf8_len = utf8_enc.len or function(s : string) : integer
	local _, count = s:gsub("[%z\001-\127\194-\253][\128-\191]*", "");
	return count;
end;

local json = require "prosody.util.json"
local null = json.null;

local pointer = require "prosody.util.jsonpointer"

local type json_type_name = json.json_type_name

-- json_type_name here is non-standard
local type schema_t = boolean | json_schema_object

local record json_schema_object
	type json_type_name = json.json_type_name
	type schema_object = json_schema_object

	-- json-schema-core meta stuff
	["$schema"] : string
	["$vocabulary"] : { string : boolean }
	["$id"] : string
	["$comment"] : string
	["$defs"] : { string : schema_t }
	["$anchor"] : string -- NYI
	["$dynamicAnchor"] : string -- NYI
	["$ref"] : string
	["$dynamicRef"] : string -- NYI

	-- combinations
	allOf : { schema_t }
	anyOf : { schema_t }
	oneOf : { schema_t }

	-- conditional logic
	["not"] : schema_t
	["if"] : schema_t
	["then"] : schema_t
	["else"] : schema_t

	dependentRequired : { string : { string } }

	-- arrays
	prefixItems : { schema_t }
	items : schema_t
	contains : schema_t

	-- objects
	properties : { string : schema_t }
	patternProperties: { string : schema_t } -- NYI
	additionalProperties: schema_t
	propertyNames : schema_t

	-- unevaluated
	unevaluatedItems : schema_t -- NYI
	unevaluatedProperties : schema_t -- NYI

	-- json-schema-validation
	type : json_type_name | { json_type_name }
	enum : { any }
	const : any

	-- numbers
	multipleOf : number
	maximum : number
	exclusiveMaximum : number
	minimum : number
	exclusiveMinimum : number

	-- strings
	maxLength : integer
	minLength : integer
	pattern : string -- NYI

	-- arrays
	maxItems : integer
	minItems : integer
	uniqueItems : boolean
	maxContains : integer
	minContains : integer

	-- objects
	maxProperties : integer -- NYI
	minProperties : integer -- NYI
	required : { string }
	dependentSchemas : { string : schema_t }

	-- semantic format
	format : string

	-- for Lua
	luaPatternProperties: { string : schema_t }
	luaPattern : string

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

local function simple_validate(schema : json_type_name | { json_type_name }, data : any) : boolean
	if schema == nil then
		return true
	elseif schema == "object" and data is table then
		return type(data) == "table" and (next(data)==nil or type((next(data, nil))) == "string")
	elseif schema == "array" and data is table then
		return type(data) == "table" and (next(data)==nil or type((next(data, nil))) == "number")
	elseif schema == "integer" then
		return math.type(data) == schema
	elseif schema == "null" then
		return data == null
	elseif schema is { json_type_name } then
		for _, one in ipairs(schema as { json_type_name }) do
			if simple_validate(one, data) then
				return true
			end
		end
		return false
	else
		return type(data) == schema
	end
end

local function validate (schema : schema_t, data : any, root : json_schema_object) : boolean
	if schema is boolean then
		return schema
	end

	if root == nil then
		root = schema
	end

	if schema["$ref"] and schema["$ref"]:sub(1,1) == "#" then
		local referenced = pointer.resolve(root as table, schema["$ref"]:sub(2)) as schema_t
		if referenced ~= nil and referenced ~= root and referenced ~= schema then
			if not validate(referenced, data, root) then
				return false;
			end
		end
	end

	if not simple_validate(schema.type, data) then
		return false;
	end

	if schema.type == "object" then
		if data is table then
			-- just check that there the keys are all strings
			for k in pairs(data) do
				if not k is string then
					return false
				end
			end
		end
	end

	if schema.type == "array" then
		if data is table then
			-- just check that there the keys are all numbers
			for i in pairs(data) do
				if not i is integer then
					return false
				end
			end
		end
	end

	if schema["enum"] ~= nil then
		local match = false
		for _, v in ipairs(schema["enum"]) do
			if v == data then
				-- FIXME supposed to do deep-compare
				match = true
				break
			end
		end
		if not match then
			return false
		end
	end

	-- XXX this is measured in byte, while JSON measures in ... bork
	-- TODO use utf8.len?
	if data is string then
		if schema.maxLength and utf8_len(data) > schema.maxLength then
			return false
		end
		if schema.minLength and utf8_len(data) < schema.minLength then
			return false
		end
		if schema.luaPattern and not data:match(schema.luaPattern) then
			return false
		end
	end

	if data is number then
		if schema.multipleOf and (data == 0 or data % schema.multipleOf ~= 0) then
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

	if data is table then
		-- tables combine object and array behavior, thus we do both kinds of
		-- validations in this block, which could be useful for validating Lua
		-- tables

		if schema.maxItems and #(data as {any}) > schema.maxItems then
			return false
		end

		if schema.minItems and #(data as {any}) < schema.minItems then
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
			-- could be used to validate non-string keys of Lua tables
			for k in pairs(data) do
				if not validate(schema.propertyNames, k, root) then
					return false
				end
			end
		end

		-- additionalProperties applies to properties not validated by properties
		-- or patternProperties, so we must keep track of properties validated by
		-- the later
		local seen_properties : { string : boolean } = {}

		if schema.properties then
			for k, sub in pairs(schema.properties) do
				if data[k] ~= nil and not validate(sub, data[k], root) then
					return false
				end
				seen_properties[k] = true
			end
		end

		if schema.luaPatternProperties then
			-- like patternProperties, but Lua patterns
			for pattern, sub in pairs(schema.luaPatternProperties) do
				for k in pairs(data) do
					if k is string and k:match(pattern) then
						if not validate(sub, data[k], root) then
							return false
						end
						seen_properties[k] = true
					end
				end
			end
		end

		if schema.additionalProperties ~= nil then
			for k, v in pairs(data) do
				if not seen_properties[k as string] then
					if not validate(schema.additionalProperties, v, root) then
						return false
					end
				end
			end
		end

		if schema.dependentSchemas then
			for k, sub in pairs(schema.dependentSchemas) do
				if data[k] ~= nil and not validate(sub, data, root) then
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
			for i = p+1, #(data as {any}) do
				if not validate(schema.items, data[i], root) then
					return false
				end
			end
		end

		if schema.contains ~= nil then
			local found = 0
			for i = 1, #(data as {any}) do
				if validate(schema.contains, data[i], root) then
					found = found + 1
				end
			end
			if found < (schema.minContains or 1) or found > (schema.maxContains or math.huge) then
				return false
			end
		end
	end

	return true;
end


json_schema_object.validate = validate;

return json_schema_object;
