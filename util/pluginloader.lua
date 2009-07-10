-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local plugin_dir = CFG_PLUGINDIR or "./plugins/";

local io_open = io.open;
local loadstring = loadstring;

module "pluginloader"

local function load_file(name)
	local file, err = io_open(plugin_dir..name);
	if not file then return file, err; end
	local content = file:read("*a");
	file:close();
	return content, name;
end

function load_resource(plugin, resource)
	if not resource then
		resource = "mod_"..plugin..".lua";
	end
	local content, err = load_file(plugin.."/"..resource);
	if not content then content, err = load_file(resource); end
	-- TODO add support for packed plugins
	return content, err;
end

function load_code(plugin, resource)
	local content, err = load_resource(plugin, resource);
	if not content then return content, err; end
	return loadstring(content, "@"..err);
end

return _M;
