-- Prosody IM v0.2
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--



local _G = _G;
local 	setmetatable, loadfile, pcall, rawget, rawset, io = 
		setmetatable, loadfile, pcall, rawget, rawset, io;

module "configmanager"

local parsers = {};

local config = { ["*"] = { core = {} } };

local global_config = config["*"];

-- When host not found, use global
setmetatable(config, { __index = function () return global_config; end});
local host_mt = { __index = global_config };

-- When key not found in section, check key in global's section
function section_mt(section_name)
	return { __index = 	function (t, k)
									local section = rawget(global_config, section_name);
									if not section then return nil; end
									return section[k];
							end };
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

function set(host, section, key, value)
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

function load(filename, format)
	format = format or filename:match("%w+$");

	if parsers[format] and parsers[format].load then
		local f, err = io.open(filename);
		if f then 
			local ok, err = parsers[format].load(f:read("*a"));
			f:close();
			return ok, err;
		end
		return f, err;
	end

	if not format then
		return nil, "no parser specified";
	else
		return nil, "no parser for "..(format);
	end
end

function save(filename, format)
end

function addparser(format, parser)
	if format and parser then
		parsers[format] = parser;
	end
end

-- Built-in Lua parser
do
	local loadstring, pcall, setmetatable = _G.loadstring, _G.pcall, _G.setmetatable;
	local setfenv, rawget, tostring = _G.setfenv, _G.rawget, _G.tostring;
	parsers.lua = {};
	function parsers.lua.load(data)
		local env;
		-- The ' = true' are needed so as not to set off __newindex when we assign the functions below
		env = setmetatable({ Host = true; host = true; Component = true, component = true }, { __index = function (t, k)
												return rawget(_G, k) or
														function (settings_table)
															config[__currenthost or "*"][k] = settings_table;
														end;
										end,
								__newindex = function (t, k, v)
											set(env.__currenthost or "*", "core", k, v);
										end});
		
		function env.Host(name)
			rawset(env, "__currenthost", name);
			-- Needs at least one setting to logically exist :)
			set(name or "*", "core", "defined", true);
		end
		env.host = env.Host;
		
		function env.Component(name)
			return function (module)
					set(name, "core", "component_module", module);
					-- Don't load the global modules by default
					set(name, "core", "modules_enable", false);
					rawset(env, "__currenthost", name);
				end
		end
		env.component = env.Component;
		
		local chunk, err = loadstring(data);
		
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
