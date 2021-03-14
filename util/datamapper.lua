local st = require("util.stanza");

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

local function parse_object(schema, s)
	local out = {}
	if schema.properties then
		for prop, propschema in pairs(schema.properties) do

			local name = prop
			local namespace = s.attr.xmlns;
			local prefix = nil
			local value_where = "in_text_tag"
			local single_attribute
			local enums

			local proptype
			if type(propschema) == "table" then
				proptype = propschema.type
			elseif type(propschema) == "string" then
				proptype = propschema
			end

			if proptype == "object" or proptype == "array" then
				value_where = "in_children"
			end

			if type(propschema) == "table" and propschema.xml then
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
				if propschema["const"] then
					enums = {propschema["const"]}
				elseif propschema["enum"] then
					enums = propschema["enum"]
				end
			end

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
				value = c.name;
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

				end
			end
			if value_where ~= "in_children" then
				out[prop] = totype(proptype, value)
			end
		end
	end

	return out
end

local function parse(schema, s)
	if schema.type == "object" then
		return parse_object(schema, s)
	end
end

local function unparse(schema, t, current_name, current_ns)
	if schema.type == "object" then

		if schema.xml then
			if schema.xml.name then
				current_name = schema.xml.name
			end
			if schema.xml.namespace then
				current_ns = schema.xml.namespace
			end

		end

		local out = st.stanza(current_name, {xmlns = current_ns})

		for prop, propschema in pairs(schema.properties) do
			local v = t[prop]

			if v ~= nil then
				local proptype
				if type(propschema) == "table" then
					proptype = propschema.type
				elseif type(propschema) == "string" then
					proptype = propschema
				end

				local name = prop
				local namespace = current_ns
				local prefix = nil
				local value_where = "in_text_tag"
				local single_attribute

				if type(propschema) == "table" and propschema.xml then

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

					end
				end
			end
		end
		return out

	end
end

return {parse = parse; unparse = unparse}
