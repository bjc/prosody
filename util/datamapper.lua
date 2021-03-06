local st = require("util.stanza");

local function toboolean(s)
	if s == "true" or s == "1" then
		return true
	elseif s == "false" or s == "0" then
		return false
	end
end

local function parse_object(schema, s)
	local out = {}
	if schema.properties then
		for prop, propschema in pairs(schema.properties) do

			local name = prop
			local namespace = s.attr.xmlns;
			local prefix = nil
			local is_attribute = false
			local is_text = false
			local name_is_value = false;

			local proptype
			if type(propschema) == "table" then
				proptype = propschema.type
			elseif type(propschema) == "string" then
				proptype = propschema
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
					is_attribute = true
				elseif propschema.xml.text then
					is_text = true
				elseif propschema.xml.x_name_is_value then
					name_is_value = true
				end
			end

			if name_is_value then
				local c = s:get_child(nil, namespace);
				if c then
					out[prop] = c.name;
				end
			elseif is_attribute then
				local attr = name
				if prefix then
					attr = prefix .. ":" .. name
				elseif namespace ~= s.attr.xmlns then
					attr = namespace .. "\1" .. name
				end
				if proptype == "string" then
					out[prop] = s.attr[attr]
				elseif proptype == "integer" or proptype == "number" then

					out[prop] = tonumber(s.attr[attr])
				elseif proptype == "boolean" then
					out[prop] = toboolean(s.attr[attr])

				end

			elseif is_text then
				if proptype == "string" then
					out[prop] = s:get_text()
				elseif proptype == "integer" or proptype == "number" then
					out[prop] = tonumber(s:get_text())
				end

			else

				if proptype == "string" then
					out[prop] = s:get_child_text(name, namespace)
				elseif proptype == "integer" or proptype == "number" then
					out[prop] = tonumber(s:get_child_text(name, namespace))
				elseif proptype == "object" and type(propschema) == "table" then
					local c = s:get_child(name, namespace)
					if c then
						out[prop] = parse_object(propschema, c);
					end

				end
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
				local is_attribute = false
				local is_text = false
				local name_is_value = false;

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
						is_attribute = true
					elseif propschema.xml.text then
						is_text = true
					elseif propschema.xml.x_name_is_value then
						name_is_value = true
					end
				end

				if is_attribute then
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
				elseif is_text then
					if type(v) == "string" then
						out:text(v)
					end
				else
					local propattr
					if namespace ~= current_ns then
						propattr = {xmlns = namespace}
					end
					if name_is_value and type(v) == "string" then
						out:tag(v, propattr):up();
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
