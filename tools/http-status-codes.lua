-- Generate net/http/codes.lua from IANA HTTP status code registry

local xml = require "util.xml";
local registry = xml.parse(io.read("*a"), { allow_processing_instructions = true });

io.write([[

local response_codes = {
	-- Source: http://www.iana.org/assignments/http-status-codes
]]);

for record in registry:get_child("registry"):childtags("record") do
	-- Extract values
	local value = record:get_child_text("value");
	local description = record:get_child_text("description");
	local ref = record:get_child_text("xref");
	local code = tonumber(value);

	-- Space between major groups
	if code and code % 100 == 0 then
		io.write("\n");
	end

	-- Reserved and Unassigned entries should be not be included
	if description == "Reserved" or description == "Unassigned" or description == "(Unused)" then
		code = nil;
	end

	-- Non-empty references become comments
	if ref and ref:find("%S") then
		ref = " -- " .. ref;
	else
		ref = "";
	end

	io.write((code and "\t[%d] = %q;%s\n" or "\t-- [%s] = %q;%s\n"):format(code or value, description, ref));
end

io.write([[};

for k,v in pairs(response_codes) do response_codes[k] = k.." "..v; end
return setmetatable(response_codes, { __index = function(_, k) return k.." Unassigned"; end })
]]);
