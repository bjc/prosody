-- Simple template language
--
-- The new() function takes a pattern and an escape function and returns 
-- a render() function.  Both are required.
--
-- The function render() takes a string template and a table of values.
-- Sequences like {name} in the template string are substituted
-- with values from the table, optionally depending on a modifier
-- symbol.
--
-- Variants are:
-- {name} is substituted for values["name"] and is escaped using the 
-- second argument to new_render().  To disable the escaping, use {name!}.
-- {name.item} can be used to access table items.
-- To renter lists of items: {name# item number {idx} is {item} }
-- Or key-value pairs: {name% t[ {idx} ] = {item} }
-- To show a defaults for missing values {name? sub-template } can be used, 
-- which renders a sub-template if values["name"] is false-ish.
-- {name& sub-template } does the opposite, the sub-template is rendered 
-- if the selected value is anything but false or nil.

local type, tostring = type, tostring;
local pairs, ipairs = pairs, ipairs;
local s_sub, s_gsub, s_match = string.sub, string.gsub, string.match;
local t_concat = table.concat;

local function new_render(pat, escape)
	-- assert(type(pat) == "string", "bad argument #1 to 'new_render' (string expected)");
	-- assert(type(escape) == "function", "bad argument #2 to 'new_render' (function expected)");
	local function render(template, values)
		-- assert(type(template) == "string", "bad argument #1 to 'render' (string expected)");
		-- assert(type(values) == "table", "bad argument #2 to 'render' (table expected)");
		return (s_gsub(template, pat, function (block)
			block = s_sub(block, 2, -2);
			local name, opt, e = s_match(block, "^([%a_][%w_.]*)(%p?)()");
			if not name then return end
			local value = values[name];
			if not value and name:find(".", 2, true) then
				value = values;
				for word in name:gmatch"[^.]+" do
					value = value[word];
					if not value then break; end
				end
			end
			if opt == '#' or opt == '%' then
				if type(value) ~= "table" then return ""; end
				local iter = opt == '#' and ipairs or pairs;
				local out, i, subtpl = {}, 1, s_sub(block, e);
				local subvalues = setmetatable({}, { __index = values });
				for idx, item in iter(value) do
					subvalues.idx = idx;
					subvalues.item = item;
					out[i], i = render(subtpl, subvalues), i+1;
				end
				return t_concat(out);
			elseif opt == '&' then
				if not value then return ""; end
				return render(s_sub(block, e), values);
			elseif opt == '?' and not value then
				return render(s_sub(block, e), values);
			elseif value ~= nil then
				if type(value) ~= "string" then
					value = tostring(value);
				end
				if opt ~= '!' then
					return escape(value);
				end
				return value;
			end
		end));
	end
	return render;
end

return {
	new = new_render;
};
