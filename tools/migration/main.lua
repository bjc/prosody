-- Command-line parsing
local options = {};
local handled_opts = 0;
for i = 1, #arg do
	if arg[i]:sub(1,2) == "--" then
		local opt, val = arg[i]:match("([%w-]+)=?(.*)");
		if opt then
			options[(opt:sub(3):gsub("%-", "_"))] = #val > 0 and val or true;
		end
		handled_opts = i;
	else
		break;
	end
end
table.remove(arg, handled_opts);

-- Load config file
local function loadfilein(file, env) return loadin and loadin(env, io.open(file):read("*a")) or setfenv(loadfile(file), env); end
config = {};
local config_env = setmetatable({}, { __index = function(t, k) return function(tbl) config[k] = tbl; end; end });
loadfilein(options.config or "config.lua", config_env)();

if not package.loaded["util.json"] then
	package.path = "../../?.lua;"..package.path
	package.cpath = "../../?.dll;"..package.cpath
end

local from_store = arg[1] or "input";
local to_store = arg[2] or "output";

assert(config[from_store], "no input specified")
assert(config[to_store], "no output specified")
local itype = assert(config[from_store].type, "no type specified for "..from_store);
local otype = assert(config[to_store].type, "no type specified for "..to_store);
local reader = require(itype).reader(config[from_store]);
local writer = require(otype).writer(config[to_store]);

local json = require "util.json";

for x in reader do
	--print(json.encode(x))
	writer(x);
end
writer(nil); -- close

