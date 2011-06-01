-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

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

function form_t.form(layout, data, formtype)
	local form = st.stanza("x", { xmlns = xmlns_forms, type = formtype or "form" });
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

		local value = (data and data[field.name]) or field.value;
		
		if value then
			-- Add value, depending on type
			if field_type == "hidden" then
				if type(value) == "table" then
					-- Assume an XML snippet
					form:tag("value")
						:add_child(value)
						:up();
				else
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
			elseif field_type == "list-single" then
				local has_default = false;
				for _, val in ipairs(value) do
					if type(val) == "table" then
						form:tag("option", { label = val.label }):tag("value"):text(val.value):up():up();
						if val.default and (not has_default) then
							form:tag("value"):text(val.value):up();
							has_default = true;
						end
					else
						form:tag("option", { label= val }):tag("value"):text(tostring(val)):up():up();
					end
				end
			elseif field_type == "list-multi" then
				for _, val in ipairs(value) do
					if type(val) == "table" then
						form:tag("option", { label = val.label }):tag("value"):text(val.value):up():up();
						if val.default then
							form:tag("value"):text(val.value):up();
						end
					else
						form:tag("option", { label= val }):tag("value"):text(tostring(val)):up():up();
					end
				end
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

local field_readers = {};

function form_t.data(layout, stanza)
	local data = {};
	
	for field_tag in stanza:childtags() do
		local field_type;
		for n, field in ipairs(layout) do
			if field.name == field_tag.attr.var then
				field_type = field.type;
				break;
			end
		end
		
		local reader = field_readers[field_type];
		if reader then
			data[field_tag.attr.var] = reader(field_tag);
		end
		
	end
	return data;
end

field_readers["text-single"] =
	function (field_tag)
		local value = field_tag:child_with_name("value");
		if value then
			return value[1];
		end
	end

field_readers["text-private"] =
	field_readers["text-single"];

field_readers["jid-single"] =
	field_readers["text-single"];

field_readers["jid-multi"] =
	function (field_tag)
		local result = {};
		for value_tag in field_tag:childtags() do
			if value_tag.name == "value" then
				result[#result+1] = value_tag[1];
			end
		end
		return result;
	end

field_readers["text-multi"] =
	function (field_tag)
		local result = {};
		for value_tag in field_tag:childtags() do
			if value_tag.name == "value" then
				result[#result+1] = value_tag[1];
			end
		end
		return t_concat(result, "\n");
	end

field_readers["list-single"] =
	field_readers["text-single"];

field_readers["list-multi"] =
	function (field_tag)
		local result = {};
		for value_tag in field_tag:childtags() do
			if value_tag.name == "value" then
				result[#result+1] = value_tag[1];
			end
		end
		return result;
	end

field_readers["boolean"] =
	function (field_tag)
		local value = field_tag:child_with_name("value");
		if value then
			if value[1] == "1" or value[1] == "true" then
				return true;
			else
				return false;
			end
		end
	end

field_readers["hidden"] =
	function (field_tag)
		local value = field_tag:child_with_name("value");
		if value then
			return value[1];
		end
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
