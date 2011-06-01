-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local _G = _G;
local setmetatable, loadfile, pcall, rawget, rawset, io, error, dofile, type, pairs, table =
      setmetatable, loadfile, pcall, rawget, rawset, io, error, dofile, type, pairs, table;
local format, math_max = string.format, math.max;

local fire_event = prosody and prosody.events.fire_event or function () end;

local lfs = require "lfs";
local path_sep = package.config:sub(1,1);

module "configmanager"

local parsers = {};

local config_mt = { __index = function (t, k) return rawget(t, "*"); end};
local config = setmetatable({ ["*"] = { core = {} } }, config_mt);

-- When host not found, use global
local host_mt = { };

-- When key not found in section, check key in global's section
function section_mt(section_name)
	return { __index = 	function (t, k)
					local section = rawget(config["*"], section_name);
					if not section then return nil; end
					return section[k];
				end
	};
end

function getconfig()
	return config;
end

function get(host, section, key)
	local sec = config[host][section];
	if sec then
		return sec[key];
	end
	return nil;
end
function _M.rawget(host, section, key)
	local hostconfig = rawget(config, host);
	if hostconfig then
		local sectionconfig = rawget(hostconfig, section);
		if sectionconfig then
			return rawget(sectionconfig, key);
		end
	end
end

local function set(config, host, section, key, value)
	if host and section and key then
		local hostconfig = rawget(config, host);
		if not hostconfig then
			hostconfig = rawset(config, host, setmetatable({}, host_mt))[host];
		end
		if not rawget(hostconfig, section) then
			hostconfig[section] = setmetatable({}, section_mt(section));
		end
		hostconfig[section][key] = value;
		return true;
	end
	return false;
end

function _M.set(host, section, key, value)
	return set(config, host, section, key, value);
end

-- Helper function to resolve relative paths (needed by config)
do
	local rel_path_start = ".."..path_sep;
	function resolve_relative_path(parent_path, path)
		if path then
			-- Some normalization
			parent_path = parent_path:gsub("%"..path_sep.."+$", "");
			path = path:gsub("^%.%"..path_sep.."+", "");
			
			local is_relative;
			if path_sep == "/" and path:sub(1,1) ~= "/" then
				is_relative = true;
			elseif path_sep == "\\" and (path:sub(1,1) ~= "/" and path:sub(2,3) ~= ":\\") then
				is_relative = true;
			end
			if is_relative then
				return parent_path..path_sep..path;
			end
		end
		return path;
	end	
end

-- Helper function to convert a glob to a Lua pattern
local function glob_to_pattern(glob)
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

function load(filename, format)
	format = format or filename:match("%w+$");

	if parsers[format] and parsers[format].load then
		local f, err = io.open(filename);
		if f then
			local new_config = setmetatable({ ["*"] = { core = {} } }, config_mt);
			local ok, err = parsers[format].load(f:read("*a"), filename, new_config);
			f:close();
			if ok then
				config = new_config;
				fire_event("config-reloaded", {
					filename = filename,
					format = format,
					config = config
				});
			end
			return ok, "parser", err;
		end
		return f, "file", err;
	end

	if not format then
		return nil, "file", "no parser specified";
	else
		return nil, "file", "no parser for "..(format);
	end
end

function save(filename, format)
end

function addparser(format, parser)
	if format and parser then
		parsers[format] = parser;
	end
end

-- _M needed to avoid name clash with local 'parsers'
function _M.parsers()
	local p = {};
	for format in pairs(parsers) do
		table.insert(p, format);
	end
	return p;
end

-- Built-in Lua parser
do
	local loadstring, pcall, setmetatable = _G.loadstring, _G.pcall, _G.setmetatable;
	local setfenv, rawget, tostring = _G.setfenv, _G.rawget, _G.tostring;
	parsers.lua = {};
	function parsers.lua.load(data, config_file, config)
		local env;
		-- The ' = true' are needed so as not to set off __newindex when we assign the functions below
		env = setmetatable({
			Host = true, host = true, VirtualHost = true,
			Component = true, component = true,
			Include = true, include = true, RunScript = true }, {
				__index = function (t, k)
					return rawget(_G, k) or
						function (settings_table)
							config[__currenthost or "*"][k] = settings_table;
						end;
				end,
				__newindex = function (t, k, v)
					set(config, env.__currenthost or "*", "core", k, v);
				end
		});
		
		rawset(env, "__currenthost", "*") -- Default is global
		function env.VirtualHost(name)
			if rawget(config, name) and rawget(config[name].core, "component_module") then
				error(format("Host %q clashes with previously defined %s Component %q, for services use a sub-domain like conference.%s",
					name, config[name].core.component_module:gsub("^%a+$", { component = "external", muc = "MUC"}), name, name), 0);
			end
			rawset(env, "__currenthost", name);
			-- Needs at least one setting to logically exist :)
			set(config, name or "*", "core", "defined", true);
			return function (config_options)
				rawset(env, "__currenthost", "*"); -- Return to global scope
				for option_name, option_value in pairs(config_options) do
					set(config, name or "*", "core", option_name, option_value);
				end
			end;
		end
		env.Host, env.host = env.VirtualHost, env.VirtualHost;
		
		function env.Component(name)
			if rawget(config, name) and rawget(config[name].core, "defined") and not rawget(config[name].core, "component_module") then
				error(format("Component %q clashes with previously defined Host %q, for services use a sub-domain like conference.%s",
					name, name, name), 0);
			end
			set(config, name, "core", "component_module", "component");
			-- Don't load the global modules by default
			set(config, name, "core", "load_global_modules", false);
			rawset(env, "__currenthost", name);
			local function handle_config_options(config_options)
				rawset(env, "__currenthost", "*"); -- Return to global scope
				for option_name, option_value in pairs(config_options) do
					set(config, name or "*", "core", option_name, option_value);
				end
			end
	
			return function (module)
					if type(module) == "string" then
						set(config, name, "core", "component_module", module);
						return handle_config_options;
					end
					return handle_config_options(module);
				end
		end
		env.component = env.Component;
		
		function env.Include(file, wildcard)
			if file:match("[*?]") then
				local path_pos, glob = file:match("()([^"..path_sep.."]+)$");
				local path = file:sub(1, math_max(path_pos-2,0));
				local config_path = config_file:gsub("[^"..path_sep.."]+$", "");
				if #path > 0 then
					path = resolve_relative_path(config_path, path);
				else
					path = config_path;
				end
				local patt = glob_to_pattern(glob);
				for f in lfs.dir(path) do
					if f:sub(1,1) ~= "." and f:match(patt) then
						env.Include(path..path_sep..f);
					end
				end
			else
				local f, err = io.open(file);
				if f then
					local data = f:read("*a");
					local file = resolve_relative_path(config_file:gsub("[^"..path_sep.."]+$", ""), file);
					local ret, err = parsers.lua.load(data, file, config);
					if not ret then error(err:gsub("%[string.-%]", file), 0); end
				end
				if not f then error("Error loading included "..file..": "..err, 0); end
				return f, err;
			end
		end
		env.include = env.Include;
		
		function env.RunScript(file)
			return dofile(resolve_relative_path(config_file:gsub("[^"..path_sep.."]+$", ""), file));
		end
		
		local chunk, err = loadstring(data, "@"..config_file);
		
		if not chunk then
			return nil, err;
		end
		
		setfenv(chunk, env);
		
		local ok, err = pcall(chunk);
		
		if not ok then
			return nil, err;
		end
		
		return true;
	end
	
end

return _M;
