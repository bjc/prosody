local st = require "util.stanza";
local js = require "util.jsonschema"

local function toboolean ( s : string ) : boolean
	if s == "true" or s == "1" then
		return true
	elseif s == "false" or s == "0" then
		return false
	end
end

local function parse_object (schema : js.schema_t, s : st.stanza_t) : table
	local out : { string : any } = {}
	if schema.properties then
		for prop, propschema in pairs(schema.properties) do
			-- TODO factor out, if it's generic enough
			local name = prop
			local namespace = s.attr.xmlns;
			local prefix : string = nil
			local is_attribute = false
			local is_text = false
			local name_is_value = false;
			local single_attribute : string

			local proptype : js.schema_t.type_e
			if propschema is js.schema_t then
				proptype = propschema.type
			elseif propschema is js.schema_t.type_e then
				proptype = propschema
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
					is_attribute = true
				elseif propschema.xml.text then
					is_text = true
				elseif propschema.xml.x_name_is_value then
					name_is_value = true
				elseif propschema.xml.x_single_attribute then
					single_attribute = propschema.xml.x_single_attribute
				end
			end

			if name_is_value then
				local c = s:get_child(nil, namespace);
				if c and proptype == "string" then
					out[prop] = c.name;
				elseif proptype == "boolean" and c then
					out[prop] = true;
				end
			elseif is_attribute then
				local attr = name
				if prefix then
					attr = prefix .. ':' .. name
				elseif namespace ~= s.attr.xmlns then
					attr = namespace .. "\1" .. name
				end
				if proptype == "string" then
					out[prop] = s.attr[attr]
				elseif proptype == "integer" or proptype == "number" then
					-- TODO floor if integer ?
					out[prop] = tonumber(s.attr[attr])
				elseif proptype == "boolean" then
					out[prop] = toboolean(s.attr[attr])
				-- else TODO
				end

			elseif is_text then
				if proptype == "string" then
					out[prop] = s:get_text()
				elseif proptype == "integer" or proptype == "number" then
					out[prop] = tonumber(s:get_text())
				end

			elseif single_attribute then
				local c = s:get_child(name, namespace)
				local a = c and c.attr[single_attribute]
				if proptype == "string" then
					out[prop] = a
				elseif proptype == "integer" or proptype == "number" then
					out[prop] = tonumber(a)
				elseif proptype == "boolean" then
					out[prop] = toboolean(a)
				end
			else

				if proptype == "string" then
					out[prop] = s:get_child_text(name, namespace)
				elseif proptype == "integer" or proptype == "number" then
					out[prop] = tonumber(s:get_child_text(name, namespace))
				elseif proptype == "object" and propschema is js.schema_t then
					local c = s:get_child(name, namespace)
					if c then
						out[prop] = parse_object(propschema, c);
					end
				-- else TODO
				end
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
				local is_attribute = false
				local is_text = false
				local name_is_value = false;
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
						is_attribute = true
					elseif propschema.xml.text then
						is_text = true
					elseif propschema.xml.x_name_is_value then
						name_is_value = true
					elseif propschema.xml.x_single_attribute then
						single_attribute = propschema.xml.x_single_attribute
					end
				end

				if is_attribute then
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
				elseif is_text then
					if v is string then
						out:text(v)
					end
				elseif single_attribute then
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
					if name_is_value then
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
