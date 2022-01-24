local s_gsub = string.gsub;
local s_match = string.match;
local s_sub = string.sub;
local t_concat = table.concat;

local st = require("util.stanza");

local function render(template, root, escape, filters)
	escape = escape or st.xml_escape;

	return (s_gsub(template, "%b{}", function(block)
		local inner = s_sub(block, 2, -2);
		local path, pipe, pos = s_match(inner, "^([^|]+)(|?)()");
		if not (type(path) == "string") then return end
		local value
		if path == "." then
			value = root;
		elseif path == "#" then
			value = root:get_text();
		else
			value = root:find(path);
		end
		local is_escaped = false;

		while pipe == "|" do
			local func, args, tmpl, p = s_match(inner, "^(%w+)(%b())(%b{})()", pos);
			if not func then func, args, p = s_match(inner, "^(%w+)(%b())()", pos); end
			if not func then func, tmpl, p = s_match(inner, "^(%w+)(%b{})()", pos); end
			if not func then func, p = s_match(inner, "^(%w+)()", pos); end
			if not func then break end
			if tmpl then tmpl = s_sub(tmpl, 2, -2); end
			if args then args = s_sub(args, 2, -2); end

			if func == "each" and tmpl and st.is_stanza(value) then
				if not args then value, args = root, path; end
				local ns, name = s_match(args, "^(%b{})(.*)$");
				if ns then
					ns = s_sub(ns, 2, -2);
				else
					name, ns = args, nil;
				end
				if ns == "" then ns = nil; end
				if name == "" then name = nil; end
				local out, i = {}, 1;
				for c in (value):childtags(name, ns) do out[i], i = render(tmpl, c, escape, filters), i + 1; end
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
			pipe, pos = s_match(inner, "^(|?)()", p);
		end

		if type(value) == "string" then
			if not is_escaped then value = escape(value); end
			return value
		elseif st.is_stanza(value) then
			value = value:get_text();
			if value then return escape(value) end
		end
		return ""
	end))
end

return { render = render }
