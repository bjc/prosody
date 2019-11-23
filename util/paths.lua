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

function path_util.complement_lua_path(installer_plugin_path)
	-- Checking for duplicates
	-- The commands using luarocks need the path to the directory that has the /share and /lib folders.
	local lua_version = _VERSION:match(" (.+)$");
	local lua_path_sep = package.config:sub(3,3);
	local dir_sep = package.config:sub(1,1);
	local sub_path = dir_sep.."lua"..dir_sep..lua_version..dir_sep;
	if not string.find(package.path, installer_plugin_path, 1, true) then
		package.path = package.path..lua_path_sep..installer_plugin_path..dir_sep.."share"..sub_path.."?.lua";
		package.path = package.path..lua_path_sep..installer_plugin_path..dir_sep.."share"..sub_path.."?"..dir_sep.."init.lua";
	end
	if not string.find(package.path, installer_plugin_path, 1, true) then
		package.cpath = package.cpath..lua_path_sep..installer_plugin_path..dir_sep.."lib"..sub_path.."?.so";
	end
end

return path_util;
