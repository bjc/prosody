-- This file is generated from teal-src/util/datamapper.lua

local st = require("util.stanza");
local pointer = require("util.jsonpointer");

local schema_t = {}

local function toboolean(s)
	if s == "true" or s == "1" then
		return true
	elseif s == "false" or s == "0" then
		return false
	elseif s then
		return true
	end
end

local function totype(t, s)
	if not s then
		return nil
	end
	if t == "string" then
		return s
	elseif t == "boolean" then
		return toboolean(s)
	elseif t == "number" or t == "integer" then
		return tonumber(s)
	end
end

local value_goes = {}

local function resolve_schema(schema, root)
	if type(schema) == "table" then
		if schema["$ref"] and schema["$ref"]:sub(1, 1) == "#" then
			return pointer.resolve(root, schema["$ref"]:sub(2))
		end
	end
	return schema
end

local function guess_schema_type(schema)
	local schema_types = schema.type
	if type(schema_types) == "string" then
		return schema_types
	elseif schema_types ~= nil then
		error("schema has unsupported 'type' property")
	elseif schema.properties then
		return "object"
	elseif schema.items then
		return "array"
	end
	return "string"
end

local function unpack_propschema(propschema, propname, current_ns)

	local proptype = "string"
	local value_where = propname and "in_text_tag" or "in_text"
	local name = propname
	local namespace
	local prefix
	local single_attribute
	local enums

	if type(propschema) == "table" then
		proptype = guess_schema_type(propschema);
	elseif type(propschema) == "string" then
		error("schema as string is not supported: " .. propschema .. " {" .. current_ns .. "}" .. propname)
	end

	if proptype == "object" or proptype == "array" then
		value_where = "in_children"
	end

	if type(propschema) == "table" then
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
			enums = {propschema["const"]}
		elseif propschema["enum"] then
			enums = propschema["enum"]
		end
	end

	return proptype, value_where, name, namespace, prefix, single_attribute, enums
end

local parse_object
local parse_array

local function extract_value(s, value_where, proptype, name, namespace, prefix, single_attribute, enums)
	if value_where == "in_tag_name" then
		local c
		if proptype == "boolean" then
			c = s:get_child(name, namespace);
		elseif enums and proptype == "string" then

			for i = 1, #enums do
				c = s:get_child(enums[i], namespace);
				if c then
					break
				end
			end
		else
			c = s:get_child(nil, namespace);
		end
		if c then
			return c.name
		end
	elseif value_where == "in_attribute" then
		local attr = name
		if prefix then
			attr = prefix .. ":" .. name
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

function parse_object(schema, s, root)
	local out = {}
	schema = resolve_schema(schema, root)
	if type(schema) == "table" and schema.properties then
		for prop, propschema in pairs(schema.properties) do
			propschema = resolve_schema(propschema, root)

			local proptype, value_where, name, namespace, prefix, single_attribute, enums = unpack_propschema(propschema, prop, s.attr.xmlns)

			if value_where == "in_children" and type(propschema) == "table" then
				if proptype == "object" then
					local c = s:get_child(name, namespace)
					if c then
						out[prop] = parse_object(propschema, c, root);
					end
				elseif proptype == "array" then
					local a = parse_array(propschema, s, root);
					if a and a[1] ~= nil then
						out[prop] = a;
					end
				else
					error("unreachable")
				end
			elseif value_where == "in_wrapper" and type(propschema) == "table" and proptype == "array" then
				local wrapper = s:get_child(name, namespace);
				if wrapper then
					out[prop] = parse_array(propschema, wrapper, root);
				end
			else
				local value = extract_value(s, value_where, proptype, name, namespace, prefix, single_attribute, enums)

				out[prop] = totype(proptype, value)
			end
		end
	end

	return out
end

function parse_array(schema, s, root)
	local itemschema = resolve_schema(schema.items, root);
	local proptype, value_where, child_name, namespace, prefix, single_attribute, enums = unpack_propschema(itemschema, nil, s.attr.xmlns)
	local attr_name
	if value_where == "in_single_attribute" then
		value_where = "in_attribute";
		attr_name = single_attribute;
	end
	local out = {}

	if proptype == "object" then
		if type(itemschema) == "table" then
			for c in s:childtags(child_name, namespace) do
				table.insert(out, parse_object(itemschema, c, root));
			end
		else
			error("array items must be schema object")
		end
	elseif proptype == "array" then
		if type(itemschema) == "table" then
			for c in s:childtags(child_name, namespace) do
				table.insert(out, parse_array(itemschema, c, root));
			end
		end
	else
		for c in s:childtags(child_name, namespace) do
			local value = extract_value(c, value_where, proptype, attr_name or child_name, namespace, prefix, single_attribute, enums)

			table.insert(out, totype(proptype, value));
		end
	end
	return out
end

local function parse(schema, s)
	local s_type = guess_schema_type(schema)
	if s_type == "object" then
		return parse_object(schema, s, schema)
	elseif s_type == "array" then
		return parse_array(schema, s, schema)
	else
		error("top-level scalars unsupported")
	end
end

local function toxmlstring(proptype, v)
	if proptype == "string" and type(v) == "string" then
		return v
	elseif proptype == "number" and type(v) == "number" then
		return string.format("%g", v)
	elseif proptype == "integer" and type(v) == "number" then
		return string.format("%d", v)
	elseif proptype == "boolean" then
		return v and "1" or "0"
	end
end

local unparse

local function unparse_property(out, v, proptype, propschema, value_where, name, namespace, current_ns, prefix,
	single_attribute, root)

	if value_where == "in_attribute" then
		local attr = name
		if prefix then
			attr = prefix .. ":" .. name
		elseif namespace and namespace ~= current_ns then
			attr = namespace .. "\1" .. name
		end

		out.attr[attr] = toxmlstring(proptype, v)
	elseif value_where == "in_text" then
		out:text(toxmlstring(proptype, v))
	elseif value_where == "in_single_attribute" then
		assert(single_attribute)
		local propattr = {}

		if namespace and namespace ~= current_ns then
			propattr.xmlns = namespace
		end

		propattr[single_attribute] = toxmlstring(proptype, v)
		out:tag(name, propattr):up();

	else
		local propattr
		if namespace ~= current_ns then
			propattr = {xmlns = namespace}
		end
		if value_where == "in_tag_name" then
			if proptype == "string" and type(v) == "string" then
				out:tag(v, propattr):up();
			elseif proptype == "boolean" and v == true then
				out:tag(name, propattr):up();
			end
		elseif proptype == "object" and type(propschema) == "table" and type(v) == "table" then
			local c = unparse(propschema, v, name, namespace, nil, root);
			if c then
				out:add_direct_child(c);
			end
		elseif proptype == "array" and type(propschema) == "table" and type(v) == "table" then
			if value_where == "in_wrapper" then
				local c = unparse(propschema, v, name, namespace, nil, root);
				if c then
					out:add_direct_child(c);
				end
			else
				unparse(propschema, v, name, namespace, out, root);
			end
		else
			out:text_tag(name, toxmlstring(proptype, v), propattr)
		end
	end
end

function unparse(schema, t, current_name, current_ns, ctx, root)

	if root == nil then
		root = schema
	end

	if schema.xml then
		if schema.xml.name then
			current_name = schema.xml.name
		end
		if schema.xml.namespace then
			current_ns = schema.xml.namespace
		end

	end

	local out = ctx or st.stanza(current_name, {xmlns = current_ns})

	local s_type = guess_schema_type(schema)
	if s_type == "object" then

		for prop, propschema in pairs(schema.properties) do
			propschema = resolve_schema(propschema, root)
			local v = t[prop]

			if v ~= nil then
				local proptype, value_where, name, namespace, prefix, single_attribute = unpack_propschema(propschema, prop, current_ns)
				unparse_property(out, v, proptype, propschema, value_where, name, namespace, current_ns, prefix, single_attribute, root)
			end
		end
		return out

	elseif s_type == "array" then
		local itemschema = resolve_schema(schema.items, root)
		local proptype, value_where, name, namespace, prefix, single_attribute = unpack_propschema(itemschema, current_name, current_ns)
		for _, item in ipairs(t) do
			unparse_property(out, item, proptype, itemschema, value_where, name, namespace, current_ns, prefix, single_attribute, root)
		end
		return out
	end
end

return {parse = parse; unparse = unparse}
