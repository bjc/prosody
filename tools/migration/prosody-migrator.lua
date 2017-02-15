#!/usr/bin/env lua

CFG_SOURCEDIR=os.getenv("PROSODY_SRCDIR");
CFG_CONFIGDIR=os.getenv("PROSODY_CFGDIR");

-- Substitute ~ with path to home directory in paths
if CFG_CONFIGDIR then
	CFG_CONFIGDIR = CFG_CONFIGDIR:gsub("^~", os.getenv("HOME"));
end

if CFG_SOURCEDIR then
	CFG_SOURCEDIR = CFG_SOURCEDIR:gsub("^~", os.getenv("HOME"));
end

local default_config = (CFG_CONFIGDIR or ".").."/migrator.cfg.lua";

-- Command-line parsing
local options = {};
local i = 1;
while arg[i] do
	if arg[i]:sub(1,2) == "--" then
		local opt, val = arg[i]:match("([%w-]+)=?(.*)");
		if opt then
			options[(opt:sub(3):gsub("%-", "_"))] = #val > 0 and val or true;
		end
		table.remove(arg, i);
	else
		i = i + 1;
	end
end

if CFG_SOURCEDIR then
	package.path = CFG_SOURCEDIR.."/?.lua;"..package.path;
	package.cpath = CFG_SOURCEDIR.."/?.so;"..package.cpath;
else
	package.path = "../../?.lua;"..package.path
	package.cpath = "../../?.so;"..package.cpath
end

local envloadfile = require "util.envload".envloadfile;

local config_file = options.config or default_config;
local from_store = arg[1] or "input";
local to_store = arg[2] or "output";

config = {};
local config_env = setmetatable({}, { __index = function(t, k) return function(tbl) config[k] = tbl; end; end });
local config_chunk, err = envloadfile(config_file, config_env);
if not config_chunk then
	print("There was an error loading the config file, check that the file exists");
	print("and that the syntax is correct:");
	print("", err);
	os.exit(1);
end

config_chunk();

local have_err;
if #arg > 0 and #arg ~= 2 then
	have_err = true;
	print("Error: Incorrect number of parameters supplied.");
end
if not config[from_store] then
	have_err = true;
	print("Error: Input store '"..from_store.."' not found in the config file.");
end
if not config[to_store] then
	have_err = true;
	print("Error: Output store '"..to_store.."' not found in the config file.");
end

function load_store_handler(name)
	local store_type = config[name].type;
	if not store_type then
		print("Error: "..name.." store type not specified in the config file");
		return false;
	else
		local ok, err = pcall(require, "migrator."..store_type);
		if not ok then
			if package.loaded["migrator."..store_type] then
				print(("Error: Failed to initialize '%s' store:\n\t%s")
					:format(name, err));
			else
				print(("Error: Unrecognised store type for '%s': %s")
					:format(from_store, store_type));
			end
			return false;
		end
	end
	return true;
end

have_err = have_err or not(load_store_handler(from_store, "input") and load_store_handler(to_store, "output"));

if have_err then
	print("");
	print("Usage: "..arg[0].." FROM_STORE TO_STORE");
	print("If no stores are specified, 'input' and 'output' are used.");
	print("");
	print("The available stores in your migrator config are:");
	print("");
	for store in pairs(config) do
		print("", store);
	end
	print("");
	os.exit(1);
end

local itype = config[from_store].type;
local otype = config[to_store].type;
local reader = require("migrator."..itype).reader(config[from_store]);
local writer = require("migrator."..otype).writer(config[to_store]);

local json = require "util.json";

io.stderr:write("Migrating...\n");
for x in reader do
	--print(json.encode(x))
	writer(x);
end
writer(nil); -- close
io.stderr:write("Done!\n");
