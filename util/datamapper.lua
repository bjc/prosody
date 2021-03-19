local st = require("util.stanza");

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
	if t == "string" then
		return s
	elseif t == "boolean" then
		return toboolean(s)
	elseif t == "number" or t == "integer" then
		return tonumber(s)
	end
end

local value_goes = {}

local function unpack_propschema(propschema, propname, current_ns)

	local proptype = "string"
	local value_where = "in_text_tag"
	local name = propname
	local namespace = current_ns
	local prefix
	local single_attribute
	local enums

	if type(propschema) == "table" then
		proptype = propschema.type
	elseif type(propschema) == "string" then
		proptype = propschema
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
			enums = {propschema["const"]}
		elseif propschema["enum"] then
			enums = propschema["enum"]
		end
	end

	return proptype, value_where, name, namespace, prefix, single_attribute, enums
end

local parse_object
local parse_array

function parse_object(schema, s)
	local out = {}
	if type(schema) == "table" and schema.properties then
		for prop, propschema in pairs(schema.properties) do

			local proptype, value_where, name, namespace, prefix, single_attribute, enums = unpack_propschema(propschema, prop, s.attr.xmlns)

			local value
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
				if type(c) == "table" then
					value = c.name;
				end
			elseif value_where == "in_attribute" then
				local attr = name
				if prefix then
					attr = prefix .. ":" .. name
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
			elseif value_where == "in_children" and type(propschema) == "table" then
				if proptype == "object" then
					local c = s:get_child(name, namespace)
					if c then
						out[prop] = parse_object(propschema, c);
					end
				elseif proptype == "array" then
					out[prop] = parse_array(propschema, s);
				else
					error("unreachable")
				end
			elseif value_where == "in_wrapper" and type(propschema) == "table" and proptype == "array" then
				local wrapper = s:get_child(name, namespace);
				if wrapper then
					out[prop] = parse_array(propschema, wrapper);
				else
					error("unreachable")
				end
			else
				error("unreachable")
			end
			if value_where ~= "in_children" and value_where ~= "in_wrapper" then
				out[prop] = totype(proptype, value)
			end
		end
	end

	return out
end

function parse_array(schema, s)
	local proptype, value_where, child_name, namespace = unpack_propschema(schema.items, nil, s.attr.xmlns)
	local out = {}
	for c in s:childtags(child_name, namespace) do
		local value;
		if value_where == "in_text_tag" then
			value = c:get_text();
		else
			error("NYI")
		end

		value = totype(proptype, value)

		if value ~= nil then
			table.insert(out, value);
		end
	end
	return out
end

local function parse(schema, s)
	if schema.type == "object" then
		return parse_object(schema, s)
	elseif schema.type == "array" then
		return parse_array(schema, s)
	else
		error("top-level scalars unsupported")
	end
end

local function unparse(schema, t, current_name, current_ns, ctx)

	if schema.xml then
		if schema.xml.name then
			current_name = schema.xml.name
		end
		if schema.xml.namespace then
			current_ns = schema.xml.namespace
		end

	end

	local out = ctx or st.stanza(current_name, {xmlns = current_ns})

	if schema.type == "object" then

		for prop, propschema in pairs(schema.properties) do
			local v = t[prop]

			if v ~= nil then

				local proptype, value_where, name, namespace, prefix, single_attribute = unpack_propschema(propschema, prop, current_ns)

				if value_where == "in_attribute" then
					local attr = name
					if prefix then
						attr = prefix .. ":" .. name
					elseif namespace ~= current_ns then
						attr = namespace .. "\1" .. name
					end

					if proptype == "string" and type(v) == "string" then
						out.attr[attr] = v
					elseif proptype == "number" and type(v) == "number" then
						out.attr[attr] = string.format("%g", v)
					elseif proptype == "integer" and type(v) == "number" then
						out.attr[attr] = string.format("%d", v)
					elseif proptype == "boolean" then
						out.attr[attr] = v and "1" or "0"
					end
				elseif value_where == "in_text" then
					if type(v) == "string" then
						out:text(v)
					end
				elseif value_where == "in_single_attribute" then
					local propattr = {}

					if namespace ~= current_ns then
						propattr.xmlns = namespace
					end

					if proptype == "string" and type(v) == "string" then
						propattr[single_attribute] = v
					elseif proptype == "number" and type(v) == "number" then
						propattr[single_attribute] = string.format("%g", v)
					elseif proptype == "integer" and type(v) == "number" then
						propattr[single_attribute] = string.format("%d", v)
					elseif proptype == "boolean" and type(v) == "boolean" then
						propattr[single_attribute] = v and "1" or "0"
					end
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
					elseif proptype == "string" and type(v) == "string" then
						out:text_tag(name, v, propattr)
					elseif proptype == "number" and type(v) == "number" then
						out:text_tag(name, string.format("%g", v), propattr)
					elseif proptype == "integer" and type(v) == "number" then
						out:text_tag(name, string.format("%d", v), propattr)
					elseif proptype == "boolean" and type(v) == "boolean" then
						out:text_tag(name, v and "1" or "0", propattr)
					elseif proptype == "object" and type(propschema) == "table" and type(v) == "table" then
						local c = unparse(propschema, v, name, namespace);
						if c then
							out:add_direct_child(c);
						end
					elseif proptype == "array" and type(propschema) == "table" and type(v) == "table" then
						if value_where == "in_wrapper" then
							local c = unparse(propschema, v, name, namespace);
							if c then
								out:add_direct_child(c);
							end
						else
							unparse(propschema, v, name, namespace, out);
						end
					else
						error("NYI")
					end
				end
			end
		end
		return out

	elseif schema.type == "array" then
		local proptype, value_where, name, namespace = unpack_propschema(schema.items, current_name, current_ns)

		if proptype == "string" then
			for _, item in ipairs(t) do
				if value_where == "in_text_tag" then
					out:text_tag(name, item, {xmlns = namespace});
				else
					error("NYI")
				end
			end
		else
			error("NYI")
		end
		return out
	end
end

return {parse = parse; unparse = unparse}
