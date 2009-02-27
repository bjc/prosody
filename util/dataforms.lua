
module "dataforms"

local xmlns_forms = 'jabber:x:data';

local form_t = {};
local form_mt = { __index = form_t };

function new(layout)
	return setmetatable(layout, form_mt);
end

local form_x_attr = { xmlns = xmlns_forms };

function form_t.form(layout, data)
	local form = st.tag("x", form_x_attr);
	for n, field in ipairs(layout) do
		local field_type = field.type;
		-- Add field tag
		form:tag("field", { type = field_type, var = field.name });

		local value = data[field.name];
		
		-- Add value, depending on type
		if field_type == "hidden" then
			if type(value) == "table" then
				-- Assume an XML snippet
				form:add_child(value);
			elseif value then
				form:text(tostring(value));
			end
		elseif field_type == "boolean" then
			form:text((value and "1") or "0");
		elseif field_type == "fixed" then
			
		elseif field_type == "jid-multi" then
			for _, jid in ipairs(value) do
				form:tag("value"):text(jid):up();
			end
		elseif field_type == "jid-single" then
			form:tag("value"):text(value):up();
			
		end
		
		-- Jump back up to list of fields
		form:up();
	end
end

function form_t.data(layout, stanza)
	
end



--[[

Layout:
{

	title = "MUC Configuration",
	instructions = [[Use this form to configure options for this MUC room.]],

	{ name = "FORM_TYPE", type = "hidden", required = true };
	{ name = "field-name", type = "field-type", required = false };
}


--]]
