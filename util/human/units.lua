local math_abs = math.abs;
local math_ceil = math.ceil;
local math_floor = math.floor;
local math_log = math.log;
local math_max = math.max;
local math_min = math.min;
local unpack = table.unpack or unpack; --luacheck: ignore 113

local large = {
	"k", 1000,
	"M", 1000000,
	"G", 1000000000,
	"T", 1000000000000,
	"P", 1000000000000000,
	"E", 1000000000000000000,
	"Z", 1000000000000000000000,
	"Y", 1000000000000000000000000,
}
local small = {
	"m", 0.001,
	"μ", 0.000001,
	"n", 0.000000001,
	"p", 0.000000000001,
	"f", 0.000000000000001,
	"a", 0.000000000000000001,
	"z", 0.000000000000000000001,
	"y", 0.000000000000000000000001,
}

local binary = {
	"Ki", 2^10,
	"Mi", 2^20,
	"Gi", 2^30,
	"Ti", 2^40,
	"Pi", 2^50,
	"Ei", 2^60,
	"Zi", 2^70,
	"Yi", 2^80,
}

-- n: number, the number to format
-- unit: string, the base unit
-- b: optional enum 'b', thousands base
local function format(n, unit, b) --> string
	local round = math_floor;
	local prefixes = large;
	local logbase = 1000;
	local fmt = "%.3g %s%s";
	if n == 0 then
		return fmt:format(n, "", unit);
	end
	if b == 'b' then
		prefixes = binary;
		logbase = 1024;
	elseif n < 1 then
		prefixes = small;
		round = math_ceil;
	end
	local m = math_max(0, math_min(8, round(math_abs(math_log(math_abs(n), logbase)))));
	local prefix, multiplier = unpack(prefixes, m * 2-1, m*2);
	return fmt:format(n / (multiplier or 1), prefix or "", unit);
end

return {
	format = format;
};
