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
				end
			end

			if is_attribute then
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

return {
	parse = parse,
	-- unparse = unparse, -- TODO
}
