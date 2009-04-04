local setmetatable = setmetatable;
local pairs, ipairs = pairs, ipairs;
local tostring, type = tostring, type;
local t_concat = table.concat;

local st = require "util.stanza";

module "dataforms"

local xmlns_forms = 'jabber:x:data';

local form_t = {};
local form_mt = { __index = form_t };

function new(layout)
	return setmetatable(layout, form_mt);
end

local form_x_attr = { xmlns = xmlns_forms };

function form_t.form(layout, data)
	local form = st.stanza("x", form_x_attr);
	if layout.title then
		form:tag("title"):text(layout.title):up();
	end
	if layout.instructions then
		form:tag("instructions"):text(layout.instructions):up();
	end
	for n, field in ipairs(layout) do
		local field_type = field.type or "text-single";
		-- Add field tag
		form:tag("field", { type = field_type, var = field.name, label = field.label });

		local value = data[field.name];
		
		-- Add value, depending on type
		if field_type == "hidden" then
			if type(value) == "table" then
				-- Assume an XML snippet
				form:tag("value")
					:add_child(value)
					:up();
			elseif value then
				form:tag("value"):text(tostring(value)):up();
			end
		elseif field_type == "boolean" then
			form:tag("value"):text((value and "1") or "0"):up();
		elseif field_type == "fixed" then
			
		elseif field_type == "jid-multi" then
			for _, jid in ipairs(value) do
				form:tag("value"):text(jid):up();
			end
		elseif field_type == "jid-single" then
			form:tag("value"):text(value):up();
		elseif field_type == "text-single" or field_type == "text-private" then
			form:tag("value"):text(value):up();
		elseif field_type == "text-multi" then
			-- Split into multiple <value> tags, one for each line
			for line in value:gmatch("([^\r\n]+)\r?\n*") do
				form:tag("value"):text(line):up();
			end
		end
		
		if field.required then
			form:tag("required"):up();
		end
		
		-- Jump back up to list of fields
		form:up();
	end
	return form;
end

function form_t.data(layout, stanza)
	
end

return _M;


--[=[

Layout:
{

	title = "MUC Configuration",
	instructions = [[Use this form to configure options for this MUC room.]],

	{ name = "FORM_TYPE", type = "hidden", required = true };
	{ name = "field-name", type = "field-type", required = false };
}


--]=]
