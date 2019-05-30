--
-- A string.format wrapper that gracefully handles invalid arguments
--

local tostring = tostring;
local unpack = table.unpack or unpack; -- luacheck: ignore 113/unpack
local pack = require "util.table".pack; -- TODO table.pack in 5.2+
local type = type;
local dump = require "util.serialization".new("debug");
local num_type = math.type or function (n)
	return n % 1 == 0 and n <= 9007199254740992 and n >= -9007199254740992 and "integer" or "float";
end

-- In Lua 5.3+ these formats throw an error if given a float
local expects_integer = { c = true, d = true, i = true, o = true, u = true, X = true, x = true, };

local function format(formatstring, ...)
	local args = pack(...);
	local args_length = args.n;

	-- format specifier spec:
	-- 1. Start: '%%'
	-- 2. Flags: '[%-%+ #0]'
	-- 3. Width: '%d?%d?'
	-- 4. Precision: '%.?%d?%d?'
	-- 5. Option: '[cdiouxXaAeEfgGqs%%]'
	--
	-- The options c, d, E, e, f, g, G, i, o, u, X, and x all expect a number as argument, whereas q and s expect a string.
	-- This function does not accept string values containing embedded zeros, except as arguments to the q option.
	-- a and A are only in Lua 5.2+


	-- process each format specifier
	local i = 0;
	formatstring = formatstring:gsub("%%[^cdiouxXaAeEfgGqs%%]*[cdiouxXaAeEfgGqs%%]", function(spec)
		if spec ~= "%%" then
			i = i + 1;
			local arg = args[i];

			local option = spec:sub(-1);
			if arg == nil then
				args[i] = "nil";
				spec = "<%s>";
			elseif option == "q" then
				args[i] = dump(arg);
				spec = "%s";
			elseif option == "s" then
				args[i] = tostring(arg);
			elseif type(arg) ~= "number" then -- arg isn't number as expected?
				args[i] = tostring(arg);
				spec = "[%s]";
			elseif expects_integer[option] and num_type(arg) ~= "integer" then
				args[i] = tostring(arg);
				spec = "[%s]";
			end
		end
		return spec;
	end);

	-- process extra args
	while i < args_length do
		i = i + 1;
		local arg = args[i];
		if arg == nil then
			args[i] = "<nil>";
		else
			args[i] = tostring(arg);
		end
		formatstring = formatstring .. " [%s]"
	end

	return formatstring:format(unpack(args));
end

return {
	format = format;
};
