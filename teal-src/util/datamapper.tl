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
-- TODO arrays
-- TODO pointers
-- TODO cleanup / refactor
--

local st = require "util.stanza";
local js = require "util.jsonschema"

local function toboolean ( s : string ) : boolean
	if s == "true" or s == "1" then
		return true
	elseif s == "false" or s == "0" then
		return false
	elseif s then
		return true
	end
end

local function totype(t : js.schema_t.type_e, s : string) : any
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

local function unpack_propschema( propschema : js.schema_t | js.schema_t.type_e, propname : string, current_ns : string )
		: js.schema_t.type_e, value_goes, string, string, string, string, { any }
	local proptype : js.schema_t.type_e = "string"
	local value_where : value_goes = "in_text_tag"
	local name = propname
	local namespace = current_ns
	local prefix : string
	local single_attribute : string
	local enums : { any }

	if propschema is js.schema_t then
		proptype = propschema.type
	elseif propschema is js.schema_t.type_e then
		proptype = propschema
	end

	if proptype == "object" or proptype == "array" then
		value_where = "in_children"
	end

	if propschema is js.schema_t then
		local xml = propschema.xml
		if xml then
			if xml.name then
				name = xml.name
			end
			if xml.namespace then
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

local parse_object : function (schema : js.schema_t, s : st.stanza_t) : { string : any }
local parse_array : function (schema : js.schema_t, s : st.stanza_t) : { any }

function parse_object (schema : js.schema_t, s : st.stanza_t) : { string : any }
	local out : { string : any } = {}
	if schema.properties then
		for prop, propschema in pairs(schema.properties) do

			local proptype, value_where, name, namespace, prefix, single_attribute, enums = unpack_propschema(propschema, prop, s.attr.xmlns)

			local value : string
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
				value = c.name;
			elseif value_where == "in_attribute" then
				local attr = name
				if prefix then
					attr = prefix .. ':' .. name
				elseif namespace ~= s.attr.xmlns then
					attr = namespace .. "\1" .. name
				end
				value = s.attr[attr]

			elseif value_where == "in_text" then
				value = s:get_text()

			elseif value_where == "in_single_attribute" then
				local c = s:get_child(name, namespace)
				value = c and c.attr[single_attribute]
			elseif value_where == "in_text_tag" then
				value = s:get_child_text(name, namespace)
			elseif value_where == "in_children" and propschema is js.schema_t then
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
			elseif value_where == "in_wrapper" and propschema is js.schema_t and proptype == "array" then
				local wrapper = s:get_child(name, namespace);
				if wrapper then
					out[prop] = parse_array(propschema, wrapper);
				else
					error "unreachable"
			end
			else
				error "unreachable"
			end
			if value_where ~= "in_children" and value_where ~= "in_wrapper" then
				out[prop] = totype(proptype, value)
			end
		end
	end

	return out
end

function parse_array (schema : js.schema_t, s : st.stanza_t) : { any }
	local proptype, value_where, child_name, namespace = unpack_propschema(schema.items, nil, s.attr.xmlns)
	local out : { any } = {}
	for c in s:childtags(child_name, namespace) do
		local value : string;
		if value_where == "in_text_tag" then
			value = c:get_text();
		else
			error "NYI"
		end

		value = totype(proptype, value)

		if value ~= nil then
			table.insert(out, value);
		end
	end
	return out;
end

local function parse (schema : js.schema_t, s : st.stanza_t) : table
	if schema.type == "object" then
		return parse_object(schema, s)
	elseif schema.type == "array" then
		return parse_array(schema, s)
	else
		error "top-level scalars unsupported"
	end
end

local function unparse ( schema : js.schema_t, t : table, current_name : string, current_ns : string ) : st.stanza_t

		if schema.xml then
			if schema.xml.name then
				current_name = schema.xml.name
			end
			if schema.xml.namespace then
				current_ns = schema.xml.namespace
			end
			-- TODO prefix?
		end

		local out = st.stanza(current_name, { xmlns = current_ns })

	if schema.type == "object" then

		for prop, propschema in pairs(schema.properties) do
			local v = t[prop]

			if v ~= nil then

				local proptype, value_where, name, namespace, prefix, single_attribute = unpack_propschema(propschema, prop, current_ns)

				if value_where == "in_attribute" then
					local attr = name
					if prefix then
						attr = prefix .. ':' .. name
					elseif namespace ~= current_ns then
						attr = namespace .. "\1" .. name
					end

					if proptype == "string" and v is string then
						out.attr[attr] = v
					elseif proptype == "number" and v is number then
						out.attr[attr] = string.format("%g", v)
					elseif proptype == "integer" and v is number then
						out.attr[attr] = string.format("%d", v)
					elseif proptype == "boolean" then
						out.attr[attr] = v and "1" or "0"
					end
				elseif value_where == "in_text" then
					if v is string then
						out:text(v)
					end
				elseif value_where == "in_single_attribute" then
					local propattr : { string : string } = {}

					if namespace ~= current_ns then
						propattr.xmlns = namespace
					end

					if proptype == "string" and v is string then
						propattr[single_attribute] = v
					elseif proptype == "number" and v is number then
						propattr[single_attribute] = string.format("%g", v)
					elseif proptype == "integer" and v is number then
						propattr[single_attribute] = string.format("%d", v)
					elseif proptype == "boolean" and v is boolean then
						propattr[single_attribute] = v and "1" or "0"
					end
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
					elseif proptype == "string" and v is string then
						out:text_tag(name, v, propattr)
					elseif proptype == "number" and v is number then
						out:text_tag(name, string.format("%g", v), propattr)
					elseif proptype == "integer" and v is number then
						out:text_tag(name, string.format("%d", v), propattr)
					elseif proptype == "boolean" and v is boolean then
						out:text_tag(name, v and "1" or "0", propattr)
					elseif proptype == "object" and propschema is js.schema_t and v is table then
						local c = unparse(propschema, v, name, namespace);
						if c then
							out:add_direct_child(c);
						end
					elseif proptype == "array" and propschema is js.schema_t and v is table then
						local c = unparse(propschema, v, name, namespace);
						if c then
							if value_where == "in_wrapper" then
								local w = st.stanza(propschema.xml.name or name, { xmlns = propschema.xml.namespace or namespace })
								w:add_direct_child(c);
								out:add_direct_child(w);
							else
								out:add_direct_child(c);
							end
						end
					else
						error "NYI"
					end
				end
			end
		end
		return out;

	elseif schema.type == "array" then
		local proptype, value_where, name, namespace = unpack_propschema(schema.items, current_name, current_ns)
		-- TODO , prefix, single_attribute
		if proptype == "string" then
			for _, item in ipairs(t as { string }) do
				if value_where == "in_text_tag" then
					out:text_tag(name, item, { xmlns = namespace });
				else
					error "NYI"
				end
			end
		else
			error "NYI"
		end
		return out;
	end
end

return {
	parse = parse,
	unparse = unparse,
}
