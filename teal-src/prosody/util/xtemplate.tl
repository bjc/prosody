-- render(template, stanza) --> string
-- {path} --> stanza:find(path)
-- {{ns}name/child|each({ns}name){sub-template}}

--[[
template ::= "{" path ("|" name ("(" args ")")? (template)? )* "}"
path ::= defined by util.stanza
name ::= %w+
args ::= anything with balanced ( ) pairs
]]

local s_gsub = string.gsub;
local s_match = string.match;
local s_sub = string.sub;
local t_concat = table.concat;

local st = require "prosody.util.stanza";

local type escape_t = function (string) : string
local type filter_t = function (string, string | st.stanza_t, string) : string | st.stanza_t, boolean
local type filter_coll = { string : filter_t }

local function render(template : string, root : st.stanza_t, escape : escape_t, filters : filter_coll) : string
	escape = escape or st.xml_escape;

	return (s_gsub(template, "%b{}", function(block : string) : string
		local inner = s_sub(block, 2, -2);
		local path, pipe, pos = s_match(inner, "^([^|]+)(|?)()");
		if not path is string then return end
		local value : string | st.stanza_t
		if path == "." then
			value = root;
		elseif path == "#" then
			value = root:get_text();
		else
			value = root:find(path);
		end
		local is_escaped = false;

		while pipe == "|" do
			local func, args, tmpl, p = s_match(inner, "^(%w+)(%b())(%b{})()", pos as integer);
			if not func then func, args, p = s_match(inner, "^(%w+)(%b())()", pos as integer); end
			if not func then func, tmpl, p = s_match(inner, "^(%w+)(%b{})()", pos as integer); end
			if not func then func, p = s_match(inner, "^(%w+)()", pos as integer); end
			if not func then break end
			if tmpl then tmpl = s_sub(tmpl, 2, -2); end
			if args then args = s_sub(args, 2, -2); end

			if func == "each" and tmpl and st.is_stanza(value) then
				if not args then value, args = root, path; end
				local ns, name = s_match(args, "^(%b{})(.*)$");
				if ns then ns = s_sub(ns, 2, -2); else name, ns = args, nil; end
				if ns == "" then ns = nil; end
				if name == "" then name = nil; end
				local out, i = {}, 1;
				for c in (value as st.stanza_t):childtags(name, ns) do
					out[i], i = render(tmpl, c, escape, filters), i + 1;
				end
				value = t_concat(out);
				is_escaped = true;
			elseif func == "and" and tmpl then
				local condition = value;
				if args then condition = root:find(args); end
				if condition then
					value = render(tmpl, root, escape, filters);
					is_escaped = true;
				end
			elseif func == "or" and tmpl then
				local condition = value;
				if args then condition = root:find(args); end
				if not condition then
					value = render(tmpl, root, escape, filters);
					is_escaped = true;
				end
			elseif filters and filters[func] then
				local f = filters[func];
				if args == nil then
					value, is_escaped = f(value, tmpl);
				else
					value, is_escaped = f(args, value, tmpl);
				end
			else
				error("No such filter function: " .. func);
			end
			pipe, pos = s_match(inner, "^(|?)()", p as integer);
		end

		if value is string then
			if not is_escaped then value = escape(value); end
			return value;
		elseif st.is_stanza(value) then
			value = value:get_text();
			if value then
				return escape(value);
			end
		end
		return "";
	end));
end

return { render = render };
