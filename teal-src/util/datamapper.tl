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
end

local function parse_object (schema : js.schema_t, s : st.stanza_t) : table
	local out : { string : any } = {}
	if schema.properties then
		for prop, propschema in pairs(schema.properties) do
			-- TODO factor out, if it's generic enough
			local name = prop
			local namespace = s.attr.xmlns;
			local prefix : string = nil
			local value_where : value_goes = "in_text_tag"
			local single_attribute : string
			local enums : { any }

			local proptype : js.schema_t.type_e
			if propschema is js.schema_t then
				proptype = propschema.type
			elseif propschema is js.schema_t.type_e then
				proptype = propschema
			end

			if proptype == "object" or proptype == "array" then
				value_where = "in_children"
			end

			if propschema is js.schema_t and propschema.xml then
				if propschema.xml.name then
					name = propschema.xml.name
				end
				if propschema.xml.namespace then
					namespace = propschema.xml.namespace
				end
				if propschema.xml.prefix then
					prefix = propschema.xml.prefix
				end
				if propschema.xml.attribute then
					value_where = "in_attribute"
				elseif propschema.xml.text then
					-- XXX Not yet in OpenAPI
					value_where = "in_text"
				elseif propschema.xml.x_name_is_value then
					-- XXX Custom extension
					value_where = "in_tag_name"
				elseif propschema.xml.x_single_attribute then
					-- XXX Custom extension
					single_attribute = propschema.xml.x_single_attribute
					value_where = "in_single_attribute"
				end
				if propschema["const"] then
					enums = { propschema["const"] }
				elseif propschema["enum"] then
					enums = propschema["enum"]
				end
			end

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
				-- else TODO
				end
			end
			if value_where ~= "in_children" then
				out[prop] = totype(proptype, value)
			end
		end
	end

	return out
end

local function parse (schema : js.schema_t, s : st.stanza_t) : table
	if schema.type == "object" then
		return parse_object(schema, s)
	end
end

local function unparse ( schema : js.schema_t, t : table, current_name : string, current_ns : string ) : st.stanza_t
	if schema.type == "object" then

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

		for prop, propschema in pairs(schema.properties) do
			local v = t[prop]

			if v ~= nil then
				local proptype : js.schema_t.type_e
				if propschema is js.schema_t then
					proptype = propschema.type
				elseif propschema is js.schema_t.type_e then
					proptype = propschema
				end

				local name = prop
				local namespace = current_ns
				local prefix : string = nil
				local value_where : value_goes = "in_text_tag"
				local single_attribute : string

				if propschema is js.schema_t and propschema.xml then

					if propschema.xml.name then
						name = propschema.xml.name
					end
					if propschema.xml.namespace then
						namespace = propschema.xml.namespace
					end

					if propschema.xml.prefix then
						prefix = propschema.xml.prefix
					end

					if propschema.xml.attribute then
						value_where = "in_attribute"
					elseif propschema.xml.text then
						value_where = "in_text"
					elseif propschema.xml.x_name_is_value then
						value_where = "in_tag_name"
					elseif propschema.xml.x_single_attribute then
						single_attribute = propschema.xml.x_single_attribute
						value_where = "in_single_attribute"
					end
				end

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
					-- else TODO
					end
				end
			end
		end
		return out;

	end
end

return {
	parse = parse,
	unparse = unparse,
}
