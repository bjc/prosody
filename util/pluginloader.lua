-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local dir_sep, path_sep = package.config:match("^(%S+)%s(%S+)");
local plugin_dir = {};
for path in (CFG_PLUGINDIR or "./plugins/"):gsub("[/\\]", dir_sep):gmatch("[^"..path_sep.."]+") do
	path = path..dir_sep; -- add path separator to path end
	path = path:gsub(dir_sep..dir_sep.."+", dir_sep); -- coalesce multiple separaters
	plugin_dir[#plugin_dir + 1] = path;
end

local io_open, os_time = io.open, os.time;
local loadstring, pairs = loadstring, pairs;

module "pluginloader"

local function load_file(name)
	local file, err, path;
	for i=1,#plugin_dir do
		path = plugin_dir[i]..name;
		file, err = io_open(path);
		if file then break; end
	end
	if not file then return file, err; end
	local content = file:read("*a");
	file:close();
	return content, path;
end

function load_resource(plugin, resource)
	local path, name = plugin:match("([^/]*)/?(.*)");
	if name == "" then
		if not resource then
			resource = "mod_"..plugin..".lua";
		end

		local content, err = load_file(plugin.."/"..resource);
		if not content then content, err = load_file(resource); end
		
		return content, err;
	else
		if not resource then
			resource = "mod_"..name..".lua";
		end

		local content, err = load_file(plugin.."/"..resource);
		if not content then content, err = load_file(path.."/"..resource); end
		
		return content, err;
	end
end

function load_code(plugin, resource)
	local content, err = load_resource(plugin, resource);
	if not content then return content, err; end
	local path = err;
	local f, err = loadstring(content, "@"..path);
	if not f then return f, err; end
	return f, path;
end

return _M;
