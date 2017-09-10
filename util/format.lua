--
-- A string.format wrapper that gracefully handles invalid arguments
--

local tostring = tostring;
local select = select;
local assert = assert;
local unpack = unpack;
local type = type;

local function format(format, ...)
	local args, args_length = { ... }, select('#', ...);

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
	format = format:gsub("%%[^cdiouxXaAeEfgGqs%%]*[cdiouxXaAeEfgGqs%%]", function(spec)
		if spec ~= "%%" then
			i = i + 1;
			local arg = args[i];
			if arg == nil then -- special handling for nil
				arg = "<nil>"
				args[i] = "<nil>";
			end

			local option = spec:sub(-1);
			if option == "q" or option == "s" then -- arg should be string
				args[i] = tostring(arg);
			elseif type(arg) ~= "number" then -- arg isn't number as expected?
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
		format = format .. " [%s]"
	end

	return format:format(unpack(args));
end

local function test()
	assert(format("%s", "hello") == "hello");
	assert(format("%s") == "<nil>");
	assert(format("%s", true) == "true");
	assert(format("%d", true) == "[true]");
	assert(format("%%", true) == "% [true]");
end

return {
	format = format;
	test = test;
};
