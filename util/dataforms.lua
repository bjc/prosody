-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local setmetatable = setmetatable;
local ipairs = ipairs;
local tostring, type, next = tostring, type, next;
local t_concat = table.concat;
local st = require "util.stanza";
local jid_prep = require "util.jid".prep;

local _ENV = nil;

local xmlns_forms = 'jabber:x:data';

local form_t = {};
local form_mt = { __index = form_t };

local function new(layout)
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
	for _, field in ipairs(layout) do
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
				form:tag("value"):text(value):up();
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

		local media = field.media;
		if media then
			form:tag("media", { xmlns = "urn:xmpp:media-element", height = media.height, width = media.width });
			for _, val in ipairs(media) do
				form:tag("uri", { type = val.type }):text(val.uri):up()
			end
			form:up();
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
	local errors = {};

	for _, field in ipairs(layout) do
		local tag;
		for field_tag in stanza:childtags("field") do
			if field.name == field_tag.attr.var then
				tag = field_tag;
				break;
			end
		end

		if not tag then
			if field.required then
				errors[field.name] = "Required value missing";
			end
		else
			local reader = field_readers[field.type];
			if reader then
				data[field.name], errors[field.name] = reader(tag, field.required);
			end
		end
	end
	if next(errors) then
		return data, errors;
	end
	return data;
end

field_readers["text-single"] =
	function (field_tag, required)
		local data = field_tag:get_child_text("value");
		if data and #data > 0 then
			return data
		elseif required then
			return nil, "Required value missing";
		end
	end

field_readers["text-private"] =
	field_readers["text-single"];

field_readers["jid-single"] =
	function (field_tag, required)
		local raw_data = field_tag:get_child_text("value")
		local data = jid_prep(raw_data);
		if data and #data > 0 then
			return data
		elseif raw_data then
			return nil, "Invalid JID: " .. raw_data;
		elseif required then
			return nil, "Required value missing";
		end
	end

field_readers["jid-multi"] =
	function (field_tag, required)
		local result = {};
		local err = {};
		for value_tag in field_tag:childtags("value") do
			local raw_value = value_tag:get_text();
			local value = jid_prep(raw_value);
			result[#result+1] = value;
			if raw_value and not value then
				err[#err+1] = ("Invalid JID: " .. raw_value);
			end
		end
		if #result > 0 then
			return result, (#err > 0 and t_concat(err, "\n") or nil);
		elseif required then
			return nil, "Required value missing";
		end
	end

field_readers["list-multi"] =
	function (field_tag, required)
		local result = {};
		for value in field_tag:childtags("value") do
			result[#result+1] = value:get_text();
		end
		if #result > 0 then
			return result;
		elseif required then
			return nil, "Required value missing";
		end
	end

field_readers["text-multi"] =
	function (field_tag, required)
		local data, err = field_readers["list-multi"](field_tag, required);
		if data then
			data = t_concat(data, "\n");
		end
		return data, err;
	end

field_readers["list-single"] =
	field_readers["text-single"];

local boolean_values = {
	["1"] = true, ["true"] = true,
	["0"] = false, ["false"] = false,
};

field_readers["boolean"] =
	function (field_tag, required)
		local raw_value = field_tag:get_child_text("value");
		local value = boolean_values[raw_value ~= nil and raw_value];
		if value ~= nil then
			return value;
		elseif raw_value then
			return nil, "Invalid boolean representation";
		elseif required then
			return nil, "Required value missing";
		end
	end

field_readers["hidden"] =
	function (field_tag)
		return field_tag:get_child_text("value");
	end

return {
	new = new;
};


--[=[

Layout:
{

	title = "MUC Configuration",
	instructions = [[Use this form to configure options for this MUC room.]],

	{ name = "FORM_TYPE", type = "hidden", required = true };
	{ name = "field-name", type = "field-type", required = false };
}


--]=]
