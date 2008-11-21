
local _G = _G;
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
	if parsers[format] and parsers[format].load then
		local f = io.open(filename);
		if f then 
			local ok, err = parsers[format](f:read("*a"));
			f:close();
			return ok, err;
		end
	end
	return false, "no parser";
end

function save(filename, format)
end

function addparser(format, parser)
	if format and parser then
		parsers[format] = parser;
	end
end

do
	parsers.lua = {};
	function parsers.lua.load(data)
		local env = setmetatable({}, { __index = function (t, k)
											if k:match("^mod_") then
												return function (settings_table)
															config[__currenthost or "*"][k] = settings_table;
														end;
											end
											return rawget(_G, k);
										end});
		
		function env.Host(name)
			env.__currenthost = name;
		end
		
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