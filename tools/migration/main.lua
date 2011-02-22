


local function loadfilein(file, env) return loadin and loadin(env, io.open(file):read("*a")) or setfenv(loadfile(file), env); end
config = {};
local config_env = setmetatable({}, { __index = function(t, k) return function(tbl) config[k] = tbl; end; end });
loadfilein("config.lua", config_env)();

package.path = "../../?.lua;"..package.path
package.cpath = "../../?.dll;"..package.cpath


assert(config.input, "no input specified")
assert(config.output, "no output specified")
local itype = assert(config.input.type, "no input.type specified");
local otype = assert(config.output.type, "no output.type specified");
local reader = require(itype).reader(config.input);
local writer = require(otype).writer(config.output);

local json = require "util.json";

for x in reader do
	--print(json.encode(x))
	writer(x);
end
writer(nil); -- close

