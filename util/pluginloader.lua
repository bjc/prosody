-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 113/CFG_PLUGINDIR

local dir_sep, path_sep = package.config:match("^(%S+)%s(%S+)");
local lua_version = _VERSION:match(" (.+)$");
local plugin_dir = {};
for path in (CFG_PLUGINDIR or "./plugins/"):gsub("[/\\]", dir_sep):gmatch("[^"..path_sep.."]+") do
	path = path..dir_sep; -- add path separator to path end
	path = path:gsub(dir_sep..dir_sep.."+", dir_sep); -- coalesce multiple separators
	plugin_dir[#plugin_dir + 1] = path;
end

local io_open = io.open;
local envload = require "prosody.util.envload".envload;

local pluginloader_methods = {};
local pluginloader_mt = { __index = pluginloader_methods };

function pluginloader_methods:load_file(names)
	local file, err, path;
	local load_filter_cb = self._options.load_filter_cb;
	local last_filter_path, last_filter_err;
	for i=1,#plugin_dir do
		for j=1,#names do
			path = plugin_dir[i]..names[j];
			file, err = io_open(path);
			if file then
				local content = file:read("*a");
				file:close();
				local metadata;
				if load_filter_cb then
					path, content, metadata = load_filter_cb(path, content);
				end
				if path and content then
					return content, path, metadata;
				else
					last_filter_path = plugin_dir[i]..names[j];
					last_filter_err = content or "skipped";
				end
			end
		end
	end
	if last_filter_err then
		return nil, err..(" (%s skipped because of %s)"):format(last_filter_path, last_filter_err);
	end
	return file, err;
end

function pluginloader_methods:load_resource(plugin, resource)
	resource = resource or "mod_"..plugin..".lua";
	local names = {
		"mod_"..plugin..dir_sep..plugin..dir_sep..resource; -- mod_hello/hello/mod_hello.lua
		"mod_"..plugin..dir_sep..resource;                  -- mod_hello/mod_hello.lua
		plugin..dir_sep..resource;                          -- hello/mod_hello.lua
		resource;                                           -- mod_hello.lua
		"share"..dir_sep.."lua"..dir_sep..lua_version..dir_sep..resource;
		"share"..dir_sep.."lua"..dir_sep..lua_version..dir_sep.."mod_"..plugin..dir_sep..resource;
	};

	return self:load_file(names);
end

function pluginloader_methods:load_code(plugin, resource, env)
	local content, err, metadata = self:load_resource(plugin, resource);
	if not content then return content, err; end
	local path = err;
	local f, err = envload(content, "@"..path, env);
	if not f then return f, err; end
	return f, path, metadata;
end

function pluginloader_methods:load_code_ext(plugin, resource, extension, env)
	local content, err, metadata = self:load_resource(plugin, resource.."."..extension);
	if not content and extension == "lib.lua" then
		content, err, metadata = self:load_resource(plugin, resource..".lua");
	end
	if not content then
		content, err, metadata = self:load_resource(resource, resource.."."..extension);
		if not content then
			return content, err;
		end
	end
	local path = err;
	local f, err = envload(content, "@"..path, env);
	if not f then return f, err; end
	return f, path, metadata;
end

local function init(options)
	return setmetatable({
		_options = options or {};
	}, pluginloader_mt);
end

local function bind(self, method)
	return function (...)
		return method(self, ...);
	end;
end

local default_loader = init();

return {
	load_file = bind(default_loader, default_loader.load_file);
	load_resource = bind(default_loader, default_loader.load_resource);
	load_code = bind(default_loader, default_loader.load_code);
	load_code_ext = bind(default_loader, default_loader.load_code_ext);

	init = init;
};
