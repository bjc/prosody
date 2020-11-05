#!/usr/bin/env lua

-- cfgdump.lua prosody.cfg.lua [[host] option]

local s_format, print = string.format, print;
local printf = function(fmt, ...) return print(s_format(fmt, ...)); end
local serialization = require"util.serialization";
local serialize = serialization.new and serialization.new({ unquoted = true }) or serialization.serialize;
local configmanager = require"core.configmanager";
local startup = require "util.startup";

startup.set_function_metatable();
local config_filename, onlyhost, onlyoption = ...;

local ok, _, err = configmanager.load(config_filename or "./prosody.cfg.lua", "lua");
assert(ok, err);

if onlyhost then
	if not onlyoption then
		onlyhost, onlyoption = "*", onlyhost;
	end
	if onlyhost ~= "*" then
		local component_module = configmanager.get(onlyhost, "component_module");

		if component_module == "component" then
			printf("Component %q", onlyhost);
		elseif component_module then
			printf("Component %q %q", onlyhost, component_module);
		else
			printf("VirtualHost %q", onlyhost);
		end
	end
	printf("%s = %s", onlyoption or "?", serialize(configmanager.get(onlyhost, onlyoption)));
	return;
end

local config = configmanager.getconfig();


for host, hostcfg in pairs(config) do
	local fixed = {};
	for option, value in pairs(hostcfg) do
		fixed[option] = value;
		if option:match("ports?$") or option:match("interfaces?$") then
			if option:match("s$") then
				if type(value) ~= "table" then
					fixed[option] = { value };
				end
			else
				if type(value) == "table" and #value > 1 then
					fixed[option] = nil;
					fixed[option.."s"] = value;
				end
			end
		end
	end
	config[host] = fixed;
end

local globals = config["*"]; config["*"] = nil;

local function printsection(section)
	local out, n = {}, 1;
	for k,v in pairs(section) do
		out[n], n = s_format("%s = %s", k, serialize(v)), n + 1;
	end
	table.sort(out);
	print(table.concat(out, "\n"));
end

print("-------------- Prosody Exported Configuration File -------------");
print();
print("------------------------ Global section ------------------------");
print();
printsection(globals);
print();

local has_components = nil;

print("------------------------ Virtual hosts -------------------------");

for host, hostcfg in pairs(config) do
	setmetatable(hostcfg, nil);
	hostcfg.defined = nil;

	if hostcfg.component_module == nil then
		print();
		printf("VirtualHost %q", host);
		printsection(hostcfg);
	else
		has_components = true
	end
end

print();

if has_components then
print("------------------------- Components ---------------------------");

	for host, hostcfg in pairs(config) do
		local component_module = hostcfg.component_module;
		hostcfg.component_module = nil;

		if component_module then
			print();
			if component_module == "component" then
				printf("Component %q", host);
			else
				printf("Component %q %q", host, component_module);
				hostcfg.component_module = nil;
				hostcfg.load_global_modules = nil;
			end
			printsection(hostcfg);
		end
	end
end

print()
print("------------------------- End of File --------------------------");

