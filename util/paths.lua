local t_concat = table.concat;

local path_sep = package.config:sub(1,1);

local path_util = {}

-- Helper function to resolve relative paths (needed by config)
function path_util.resolve_relative_path(parent_path, path)
	if path then
		-- Some normalization
		parent_path = parent_path:gsub("%"..path_sep.."+$", "");
		path = path:gsub("^%.%"..path_sep.."+", "");

		local is_relative;
		if path_sep == "/" and path:sub(1,1) ~= "/" then
			is_relative = true;
		elseif path_sep == "\\" and (path:sub(1,1) ~= "/" and (path:sub(2,3) ~= ":\\" and path:sub(2,3) ~= ":/")) then
			is_relative = true;
		end
		if is_relative then
			return parent_path..path_sep..path;
		end
	end
	return path;
end

-- Helper function to convert a glob to a Lua pattern
function path_util.glob_to_pattern(glob)
	return "^"..glob:gsub("[%p*?]", function (c)
		if c == "*" then
			return ".*";
		elseif c == "?" then
			return ".";
		else
			return "%"..c;
		end
	end).."$";
end

function path_util.join(...)
	return t_concat({...}, path_sep);
end

return path_util;
