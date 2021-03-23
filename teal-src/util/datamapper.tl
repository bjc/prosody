-- Copyright (C) 2021 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- Based on
-- https://json-schema.org/draft/2020-12/json-schema-core.html
-- https://json-schema.org/draft/2020-12/json-schema-validation.html
-- http://spec.openapis.org/oas/v3.0.1#xmlObject
-- https://github.com/OAI/OpenAPI-Specification/issues/630 (text:true)
--
-- XML Object Extensions:
-- text to refer to the text content at the same time as attributes
-- x_name_is_value for enum fields where the <tag-name/> is the value
-- x_single_attribute for <tag attr="this"/>
--
-- TODO pointers
-- TODO cleanup / refactor
-- TODO s/number/integer/ once we have appropriate math.type() compat
--

local st = require "util.stanza";
local json = require"util.json"

local json_type_name = json.json_type_name;
local json_schema_object = require "util.jsonschema"
local type schema_t = boolean | json_type_name | json_schema_object

local function toboolean ( s : string ) : boolean
	if s == "true" or s == "1" then
		return true
	elseif s == "false" or s == "0" then
		return false
	elseif s then
		return true
	end
end

local function totype(t : json_type_name, s : string) : any
	if t == "string" then
		return s;
	elseif t == "boolean" then
		return toboolean(s)
	elseif t == "number" or t == "integer" then
		return tonumber(s)
	end
end

local enum value_goes
	"in_tag_name"
	"in_text"
	"in_text_tag"
	"in_attribute"
	"in_single_attribute"
	"in_children"
	"in_wrapper"
end

local function unpack_propschema( propschema : schema_t, propname : string, current_ns : string )
		: json_type_name, value_goes, string, string, string, string, { any }
	local proptype : json_type_name = "string"
	local value_where : value_goes = propname and "in_text_tag" or "in_text"
	local name = propname
	local namespace : string
	local prefix : string
	local single_attribute : string
	local enums : { any }

	if propschema is json_schema_object then
		proptype = propschema.type
	elseif propschema is json_type_name then
		proptype = propschema
	end

	if proptype == "object" or proptype == "array" then
		value_where = "in_children"
	end

	if propschema is json_schema_object then
		local xml = propschema.xml
		if xml then
			if xml.name then
				name = xml.name
			end
			if xml.namespace and xml.namespace ~= current_ns then
				namespace = xml.namespace
			end
			if xml.prefix then
				prefix = xml.prefix
			end
			if proptype == "array" and xml.wrapped then
				value_where = "in_wrapper"
			elseif xml.attribute then
				value_where = "in_attribute"
			elseif xml.text then
				value_where = "in_text"
			elseif xml.x_name_is_value then
				value_where = "in_tag_name"
			elseif xml.x_single_attribute then
				single_attribute = xml.x_single_attribute
				value_where = "in_single_attribute"
			end
		end
		if propschema["const"] then
			enums = { propschema["const"] }
		elseif propschema["enum"] then
			enums = propschema["enum"]
		end
	end

	return proptype, value_where, name, namespace, prefix, single_attribute, enums
end

local parse_object : function (schema : schema_t, s : st.stanza_t) : { string : any }
local parse_array : function (schema : schema_t, s : st.stanza_t) : { any }

local function extract_value (s : st.stanza_t, value_where : value_goes, proptype : json.json_type_name, name : string, namespace : string, prefix : string, single_attribute : string, enums : { any }) : string
	if value_where == "in_tag_name" then
		local c : st.stanza_t
		if proptype == "boolean" then
			c = s:get_child(name, namespace);
		elseif enums and proptype == "string" then
			-- XXX O(n²) ?
			-- Probably better to flip the table and loop over :childtags(nil, ns), should be 2xO(n)
			-- BUT works first, optimize later
			for i = 1, #enums do
				c = s:get_child(enums[i] as string, namespace);
				if c then break end
			end
		else
			c = s:get_child(nil, namespace);
		end
		if c then
			return c.name;
		end
	elseif value_where == "in_attribute" then
		local attr = name
		if prefix then
			attr = prefix .. ':' .. name
		elseif namespace and namespace ~= s.attr.xmlns then
			attr = namespace .. "\1" .. name
		end
		return s.attr[attr]

	elseif value_where == "in_text" then
		return s:get_text()

	elseif value_where == "in_single_attribute" then
		local c = s:get_child(name, namespace)
		return c and c.attr[single_attribute]
	elseif value_where == "in_text_tag" then
		return s:get_child_text(name, namespace)
	end
end

function parse_object (schema : schema_t, s : st.stanza_t) : { string : any }
	local out : { string : any } = {}
	if schema is json_schema_object and schema.properties then
		for prop, propschema in pairs(schema.properties) do

			local proptype, value_where, name, namespace, prefix, single_attribute, enums = unpack_propschema(propschema, prop, s.attr.xmlns)

			if value_where == "in_children" and propschema is json_schema_object then
				if proptype == "object" then
					local c = s:get_child(name, namespace)
					if c then
						out[prop] = parse_object(propschema, c);
					end
				elseif proptype == "array" then
					out[prop] = parse_array(propschema, s);
				else
					error "unreachable"
				end
			elseif value_where == "in_wrapper" and propschema is json_schema_object and proptype == "array" then
				local wrapper = s:get_child(name, namespace);
				if wrapper then
					out[prop] = parse_array(propschema, wrapper);
				end
			else
				local value : string = extract_value (s, value_where, proptype, name, namespace, prefix, single_attribute, enums)

				out[prop] = totype(proptype, value)
			end
		end
	end

	return out
end

function parse_array (schema : json_schema_object, s : st.stanza_t) : { any }
	local itemschema : schema_t = schema.items;
	local proptype, value_where, child_name, namespace, prefix, single_attribute, enums = unpack_propschema(itemschema, nil, s.attr.xmlns)
	local attr_name : string
	if value_where == "in_single_attribute" then -- FIXME this shouldn't be needed
		value_where = "in_attribute";
		attr_name = single_attribute;
	end
	local out : { any } = {}

	if proptype == "object" then
		if itemschema is json_schema_object then
			for c in s:childtags(child_name, namespace) do
				table.insert(out, parse_object(itemschema, c));
			end
		else
			error "array items must be schema object"
		end
	elseif proptype == "array" then
		if itemschema is json_schema_object then
			for c in s:childtags(child_name, namespace) do
				table.insert(out, parse_array(itemschema, c));
			end
		end
	else
		for c in s:childtags(child_name, namespace) do
			local value : string = extract_value (c, value_where, proptype, attr_name or child_name, namespace, prefix, single_attribute, enums)

			table.insert(out, totype(proptype, value));
		end
	end
	return out;
end

local function parse (schema : json_schema_object, s : st.stanza_t) : table
	if schema.type == "object" then
		return parse_object(schema, s)
	elseif schema.type == "array" then
		return parse_array(schema, s)
	else
		error "top-level scalars unsupported"
	end
end

local function toxmlstring(proptype : json_type_name, v : any) : string
	if proptype == "string" and v is string then
		return  v
	elseif proptype == "number" and v is number then
		return  string.format("%g", v)
	elseif proptype == "integer" and v is number then -- TODO is integer
		return  string.format("%d", v)
	elseif proptype == "boolean" then
		return  v and "1" or "0"
	end
end

local unparse : function (json_schema_object, table, string, string, st.stanza_t) : st.stanza_t

local function unparse_property(out : st.stanza_t, v : any, proptype : json_type_name, propschema : schema_t, value_where : value_goes, name : string, namespace : string, current_ns : string, prefix : string, single_attribute : string)
	if value_where == "in_attribute" then
		local attr = name
		if prefix then
			attr = prefix .. ':' .. name
		elseif namespace and namespace ~= current_ns then
			attr = namespace .. "\1" .. name
		end

		out.attr[attr] = toxmlstring(proptype, v)
	elseif value_where == "in_text" then
		out:text(toxmlstring(proptype, v))
	elseif value_where == "in_single_attribute" then
		assert(single_attribute)
		local propattr : { string : string } = {}

		if namespace and namespace ~= current_ns then
			propattr.xmlns = namespace
		end

		propattr[single_attribute] = toxmlstring(proptype, v)
		out:tag(name, propattr):up();

	else
		local propattr : { string : string }
		if namespace ~= current_ns then
			propattr = { xmlns = namespace }
		end
		if value_where == "in_tag_name" then
			if proptype == "string" and v is string then
				out:tag(v, propattr):up();
			elseif proptype == "boolean" and v == true then
				out:tag(name, propattr):up();
			end
		elseif proptype == "object" and propschema is json_schema_object and v is table then
			local c = unparse(propschema, v, name, namespace);
			if c then
				out:add_direct_child(c);
			end
		elseif proptype == "array" and propschema is json_schema_object and v is table then
			if value_where == "in_wrapper" then
				local c = unparse(propschema, v, name, namespace);
				if c then
					out:add_direct_child(c);
				end
			else
				unparse(propschema, v, name, namespace, out);
			end
		else
			out:text_tag(name, toxmlstring(proptype, v), propattr)
		end
	end
end

function unparse ( schema : json_schema_object, t : table, current_name : string, current_ns : string, ctx : st.stanza_t ) : st.stanza_t

	if schema.xml then
		if schema.xml.name then
			current_name = schema.xml.name
		end
		if schema.xml.namespace then
			current_ns = schema.xml.namespace
		end
		-- TODO prefix?
	end

	local out = ctx or st.stanza(current_name, { xmlns = current_ns })

	if schema.type == "object" then

		for prop, propschema in pairs(schema.properties) do
			local v = t[prop]

			if v ~= nil then
				local proptype, value_where, name, namespace, prefix, single_attribute = unpack_propschema(propschema, prop, current_ns)
				unparse_property(out, v, proptype, propschema, value_where, name, namespace, current_ns, prefix, single_attribute)
			end
		end
		return out;

	elseif schema.type == "array" then
		local proptype, value_where, name, namespace, prefix, single_attribute = unpack_propschema(schema.items, current_name, current_ns)
		for _, item in ipairs(t as { string }) do
			unparse_property(out, item, proptype, schema.items, value_where, name, namespace, current_ns, prefix, single_attribute)
		end
		return out;
	end
end

return {
	parse = parse,
	unparse = unparse,
}
