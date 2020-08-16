-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local setmetatable = setmetatable;
local ipairs = ipairs;
local type, next = type, next;
local tonumber = tonumber;
local t_concat = table.concat;
local st = require "util.stanza";
local jid_prep = require "util.jid".prep;

local _ENV = nil;
-- luacheck: std none

local xmlns_forms = 'jabber:x:data';
local xmlns_validate = 'http://jabber.org/protocol/xdata-validate';

local form_t = {};
local form_mt = { __index = form_t };

local function new(layout)
	return setmetatable(layout, form_mt);
end

function form_t.form(layout, data, formtype)
	if not formtype then formtype = "form" end
	local form = st.stanza("x", { xmlns = xmlns_forms, type = formtype });
	if formtype == "cancel" then
		return form;
	end
	if formtype ~= "submit" then
		if layout.title then
			form:tag("title"):text(layout.title):up();
		end
		if layout.instructions then
			form:tag("instructions"):text(layout.instructions):up();
		end
	end
	for _, field in ipairs(layout) do
		local field_type = field.type or "text-single";
		-- Add field tag
		form:tag("field", { type = field_type, var = field.var or field.name, label = formtype ~= "submit" and field.label or nil });

		if formtype ~= "submit" then
			if field.desc then
				form:text_tag("desc", field.desc);
			end
		end

		if formtype == "form" and field.datatype then
			form:tag("validate", { xmlns = xmlns_validate, datatype = field.datatype });
			-- <basic/> assumed
			form:up();
		end


		local value = field.value;
		local options = field.options;

		if data and data[field.name] ~= nil then
			value = data[field.name];

			if formtype == "form" and type(value) == "table"
				and (field_type == "list-single" or field_type == "list-multi") then
				-- Allow passing dynamically generated options as values
				options, value = value, nil;
			end
		end

		if formtype == "form" and options then
			local defaults = {};
			for _, val in ipairs(options) do
				if type(val) == "table" then
					form:tag("option", { label = val.label }):tag("value"):text(val.value):up():up();
					if val.default then
						defaults[#defaults+1] = val.value;
					end
				else
					form:tag("option", { label= val }):tag("value"):text(val):up():up();
				end
			end
			if not value then
				if field_type == "list-single" then
					value = defaults[1];
				elseif field_type == "list-multi" then
					value = defaults;
				end
			end
		end

		if value ~= nil then
			if type(value) == "number" then
				-- TODO validate that this is ok somehow, eg check field.datatype
				value = ("%g"):format(value);
			end
			-- Add value, depending on type
			if field_type == "hidden" then
				if type(value) == "table" then
					-- Assume an XML snippet
					form:tag("value")
						:add_child(value)
						:up();
				else
					form:tag("value"):text(value):up();
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
				form:tag("value"):text(value):up();
			elseif field_type == "list-multi" then
				for _, val in ipairs(value) do
					form:tag("value"):text(val):up();
				end
			end
		end

		local media = field.media;
		if media then
			form:tag("media", { xmlns = "urn:xmpp:media-element", height = ("%g"):format(media.height), width = ("%g"):format(media.width) });
			for _, val in ipairs(media) do
				form:tag("uri", { type = val.type }):text(val.uri):up()
			end
			form:up();
		end

		if formtype == "form" and field.required then
			form:tag("required"):up();
		end

		-- Jump back up to list of fields
		form:up();
	end
	return form;
end

local field_readers = {};
local data_validators = {};

function form_t.data(layout, stanza, current)
	local data = {};
	local errors = {};
	local present = {};

	for _, field in ipairs(layout) do
		local tag;
		for field_tag in stanza:childtags("field") do
			if (field.var or field.name) == field_tag.attr.var then
				tag = field_tag;
				break;
			end
		end

		if not tag then
			if current and current[field.name] ~= nil then
				data[field.name] = current[field.name];
			elseif field.required then
				errors[field.name] = "Required value missing";
			end
		elseif field.name then
			present[field.name] = true;
			local reader = field_readers[field.type];
			if reader then
				local value, err = reader(tag, field.required);
				local validator = field.datatype and data_validators[field.datatype];
				if value ~= nil and validator then
					local valid, ret = validator(value, field);
					if valid then
						value = ret;
					else
						value, err = nil, ret or ("Invalid value for data of type " .. field.datatype);
					end
				end
				data[field.name], errors[field.name] = value, err;
			end
		end
	end
	if next(errors) then
		return data, errors, present;
	end
	return data, nil, present;
end

local function simple_text(field_tag, required)
	local data = field_tag:get_child_text("value");
	-- XEP-0004 does not say if an empty string is acceptable for a required value
	-- so we will follow HTML5 which says that empty string means missing
	if required and (data == nil or data == "") then
		return nil, "Required value missing";
	end
	return data; -- Return whatever get_child_text returned, even if empty string
end

field_readers["text-single"] = simple_text;

field_readers["text-private"] = simple_text;

field_readers["jid-single"] =
	function (field_tag, required)
		local raw_data, err = simple_text(field_tag, required);
		if not raw_data then return raw_data, err; end
		local data = jid_prep(raw_data);
		if not data then
			return nil, "Invalid JID: " .. raw_data;
		end
		return data;
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

field_readers["list-single"] = simple_text;

local boolean_values = {
	["1"] = true, ["true"] = true,
	["0"] = false, ["false"] = false,
};

field_readers["boolean"] =
	function (field_tag, required)
		local raw_value, err = simple_text(field_tag, required);
		if not raw_value then return raw_value, err; end
		local value = boolean_values[raw_value];
		if value == nil then
			return nil, "Invalid boolean representation:" .. raw_value;
		end
		return value;
	end

field_readers["hidden"] =
	function (field_tag)
		return field_tag:get_child_text("value");
	end

data_validators["xs:integer"] =
	function (data)
		local n = tonumber(data);
		if not n then
			return false, "not a number";
		elseif n % 1 ~= 0 then
			return false, "not an integer";
		end
		return true, n;
	end


local function get_form_type(form)
	if not st.is_stanza(form) then
		return nil, "not a stanza object";
	elseif form.attr.xmlns ~= "jabber:x:data" or form.name ~= "x" then
		return nil, "not a dataform element";
	end
	for field in form:childtags("field") do
		if field.attr.var == "FORM_TYPE" then
			return field:get_child_text("value");
		end
	end
	return "";
end

return {
	new = new;
	get_type = get_form_type;
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
