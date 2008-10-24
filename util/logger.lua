
local format = string.format;
local print = print;
local debug = debug;
local tostring = tostring;
module "logger"

function init(name)
	--name = nil; -- While this line is not commented, will automatically fill in file/line number info
	return 	function (level, message, ...)
				if not name then
					local inf = debug.getinfo(3, 'Snl');
					level = level .. ","..tostring(inf.short_src):match("[^/]*$")..":"..inf.currentline;
				end
				if ... then 
					print(level, format(message, ...));
				else
					print(level, message);
				end
			end
end

return _M;