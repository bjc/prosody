-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local plugin_dir = CFG_PLUGINDIR or "./plugins/";

local io_open, os_time = io.open, os.time;
local loadstring, pairs = loadstring, pairs;

local datamanager = require "util.datamanager";

module "pluginloader"

local function load_file(name)
	local file, err = io_open(plugin_dir..name);
	if not file then return file, err; end
	local content = file:read("*a");
	file:close();
	return content, name;
end

function load_resource(plugin, resource, loader)
	local path, name = plugin:match("([^/]*)/?(.*)");
	if name == "" then
		if not resource then
			resource = "mod_"..plugin..".lua";
		end
		loader = loader or load_file;

		local content, err = loader(plugin.."/"..resource);
		if not content then content, err = loader(resource); end
		-- TODO add support for packed plugins
		
		return content, err;
	else
		if not resource then
			resource = "mod_"..name..".lua";
		end
		loader = loader or load_file;

		local content, err = loader(plugin.."/"..resource);
		if not content then content, err = loader(path.."/"..resource); end
		-- TODO add support for packed plugins
		
		return content, err;
	end
end

function load_code(plugin, resource)
	local content, err = load_resource(plugin, resource);
	if not content then return content, err; end
	return loadstring(content, "@"..err);
end

return _M;
