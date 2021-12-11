local format = require"util.format".format;
local dump = require"util.serialization".new("oneline")
local types = {
	"nil";
	"boolean";
	"number";
	"string";
	"function";
	-- "userdata";
	"thread";
	"table";
};
local example_values = {
	["nil"] = { n = 1; nil };
	["boolean"] = { true; false };
	["number"] = { 97; -12345; 1.5; 73786976294838206464; math.huge; 2147483647 };
	["string"] = { "hello"; "foo \1\2\3 bar"; "nödåtgärd"; string.sub("nödåtgärd", 1, -4) };
	["function"] = { function() end };
	-- ["userdata"] = {};
	["thread"] = { coroutine.create(function() end) };
	["table"] = { {} };
};
local example_strings = setmetatable({
	["nil"] = { "nil" };
	["function"] = { "function() end" };
	["number"] = { "97"; "-12345"; "1.5"; "73786976294838206464"; "math.huge"; "2147483647" };
	["thread"] = { "coroutine.create(function() end)" };
}, { __index = function() return {} end });
for _, lua_type in ipairs(types) do
	print(string.format("\t\tdescribe(\"%s\", function ()", lua_type));
	local examples = example_values[lua_type];
	for fmt in ("cdiouxXaAeEfgGqs"):gmatch(".") do
		print(string.format("\t\t\tdescribe(\"to %%%s\", function ()", fmt));
		print("\t\t\t\tit(\"works\", function ()");
		for i = 1, examples.n or #examples do
			local example = examples[i];
			if not tostring(example):match("%w+: 0[xX]%x+") then
				print(string.format("\t\t\t\t\tassert.equal(%q, format(%q, %s))", format("%" .. fmt, example), "%" .. fmt,
					example_strings[lua_type][i] or dump(example)));
			else
				print(string.format("\t\t\t\t\tassert.matches(\"[%s: 0[xX]%%x+]\", format(%q, %s))", lua_type, "%" .. fmt,
					example_strings[lua_type][i] or dump(example)));
			end
		end
		print("\t\t\t\tend);");
		print("\t\t\tend);");
		print()
	end
	print("\t\tend);");
	print()
end
