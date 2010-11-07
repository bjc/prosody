-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local _G = _G;
local 	setmetatable, loadfile, pcall, rawget, rawset, io, error, dofile, type, pairs, table, format =
		setmetatable, loadfile, pcall, rawget, rawset, io, error, dofile, type, pairs, table, string.format;


local fire_event = prosody and prosody.events.fire_event or function () end;

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

function load(filename, format)
	format = format or filename:match("%w+$");

	if parsers[format] and parsers[format].load then
		local f, err = io.open(filename);
		if f then
			local new_config, err = parsers[format].load(f:read("*a"), filename);
			f:close();
			if new_config then
				setmetatable(new_config, config_mt);
				config = new_config;
				fire_event("config-reloaded", {
					filename = filename,
					format = format,
					config = config
				});
			end
			return not not new_config, "parser", err;
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
	function parsers.lua.load(data, filename)
		local config = { ["*"] = { core = {} } };
	
		local env;
		-- The ' = true' are needed so as not to set off __newindex when we assign the functions below
		env = setmetatable({
			Host = true, host = true, VirtualHost = true,
			Component = true, component = true,
			Include = true, include = true, RunScript = dofile }, {
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
		
		function env.Include(file)
			local f, err = io.open(file);
			if f then
				local data = f:read("*a");
				local ok, err = parsers.lua.load(data, file);
				if not ok then error(err:gsub("%[string.-%]", file), 0); end
			end
			if not f then error("Error loading included "..file..": "..err, 0); end
			return f, err;
		end
		env.include = env.Include;
		
		local chunk, err = loadstring(data, "@"..filename);
		
		if not chunk then
			return nil, err;
		end
		
		setfenv(chunk, env);
		
		local ok, err = pcall(chunk);
		
		if not ok then
			return nil, err;
		end
		
		return config;
	end
	
end

return _M;
