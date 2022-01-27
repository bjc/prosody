--
-- A string.format wrapper that gracefully handles invalid arguments since
-- certain format string and argument combinations may casue errors or other
-- issues like log spoofing
--
-- Provides some protection from e.g. CAPEC-135, CWE-117, CWE-134, CWE-93

local tostring = tostring;
local unpack = table.unpack or unpack; -- luacheck: ignore 113/unpack
local pack = require "util.table".pack; -- TODO table.pack in 5.2+
local valid_utf8 = require "util.encodings".utf8.valid;
local type = type;
local dump = require "util.serialization".new("debug");
local num_type = math.type or function (n)
	return n % 1 == 0 and n <= 9007199254740992 and n >= -9007199254740992 and "integer" or "float";
end

-- In Lua 5.3+ these formats throw an error if given a float
local expects_integer = { c = true, d = true, i = true, o = true, u = true, X = true, x = true, };
-- In Lua 5.2 these throw an error given a negative number
local expects_positive = { o = true; u = true; x = true; X = true };
-- Printable Unicode replacements for control characters
local control_symbols = {
	-- 0x00 .. 0x1F --> U+2400 .. U+241F, 0x7F --> U+2421
	["\000"] = "\226\144\128", ["\001"] = "\226\144\129", ["\002"] = "\226\144\130",
	["\003"] = "\226\144\131", ["\004"] = "\226\144\132", ["\005"] = "\226\144\133",
	["\006"] = "\226\144\134", ["\007"] = "\226\144\135", ["\008"] = "\226\144\136",
	["\009"] = "\226\144\137", ["\010"] = "\226\144\138", ["\011"] = "\226\144\139",
	["\012"] = "\226\144\140", ["\013"] = "\226\144\141", ["\014"] = "\226\144\142",
	["\015"] = "\226\144\143", ["\016"] = "\226\144\144", ["\017"] = "\226\144\145",
	["\018"] = "\226\144\146", ["\019"] = "\226\144\147", ["\020"] = "\226\144\148",
	["\021"] = "\226\144\149", ["\022"] = "\226\144\150", ["\023"] = "\226\144\151",
	["\024"] = "\226\144\152", ["\025"] = "\226\144\153", ["\026"] = "\226\144\154",
	["\027"] = "\226\144\155", ["\028"] = "\226\144\156", ["\029"] = "\226\144\157",
	["\030"] = "\226\144\158", ["\031"] = "\226\144\159", ["\127"] = "\226\144\161",
};
local supports_p = pcall(string.format, "%p", ""); -- >= Lua 5.4
local supports_a = pcall(string.format, "%a", 0.0); -- > Lua 5.1

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
	-- Lua 5.4 adds a p format that produces a pointer


	-- process each format specifier
	local i = 0;
	formatstring = formatstring:gsub("%%[^cdiouxXaAeEfgGpqs%%]*[cdiouxXaAeEfgGpqs%%]", function(spec)
		if spec == "%%" then return end
		i = i + 1;
		local arg = args[i];

		if arg == nil then
			args[i] = "nil";
			return "(%s)";
		end

		local option = spec:sub(-1);
		local t = type(arg);

		if option == "s" and t == "string" and not arg:find("[%z\1-\31\128-\255]") then
			-- No UTF-8 or control characters, assumed to be the common case.
			return
		elseif t == "number" then
			if option == "g" or (option == "d" and num_type(arg) == "integer") then return end
		elseif option == "s" and t ~= "string" then
			arg = tostring(arg);
			t = "string";
		end

		if option ~= "s" and option ~= "q" and option ~= "p" then
			-- all other options expect numbers
			if t ~= "number" then
				-- arg isn't number as expected?
				arg = tostring(arg);
				option = "s";
				spec = "[%s]";
				t = "string";
			elseif expects_integer[option] and num_type(arg) ~= "integer" then
				args[i] = tostring(arg);
				return "[%s]";
			elseif expects_positive[option] and arg < 0 then
				args[i] = tostring(arg);
				return "[%s]";
			elseif (option == "a" or option == "A") and not supports_a then
				return "%x";
			else
				return -- acceptable number
			end
		end


		if option == "p" and not supports_p then
			arg = tostring(arg);
			option = "s";
			spec = "[%s]";
			t = "string";
		end

		if t == "string" and option ~= "p" then
			if not valid_utf8(arg) then
				option = "q";
			elseif option ~= "q" then -- gets fully escaped in the next block
				-- Prevent funny things with ASCII control characters and ANSI escape codes (CWE-117)
				-- Also ensure embedded newlines can't look like another log line (CWE-93)
				args[i] = arg:gsub("[%z\1-\8\11-\31\127]", control_symbols):gsub("\n\t?", "\n\t");
				return spec;
			end
		end

		if option == "q" then
			args[i] = dump(arg);
			return "%s";
		end

		if option == "p" and (t == "boolean" or t == "number") then
			args[i] = tostring(arg);
			return "[%s]";
		end
	end);

	-- process extra args
	while i < args_length do
		i = i + 1;
		local arg = args[i];
		if arg == nil then
			args[i] = "(nil)";
		else
			args[i] = tostring(arg):gsub("[%z\1-\8\11-\31\127]", control_symbols):gsub("\n\t?", "\n\t");
		end
		formatstring = formatstring .. " [%s]"
	end

	return formatstring:format(unpack(args));
end

return {
	format = format;
};
