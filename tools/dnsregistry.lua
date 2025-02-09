-- Generate util/dnsregistry.lua from IANA HTTP status code registry
if not pcall(require, "prosody.loader") then
	pcall(require, "loader");
end
local xml = require "prosody.util.xml";
local registries = xml.parse(io.read("*a"), { allow_processing_instructions = true });

print("-- Source: https://www.iana.org/assignments/dns-parameters/dns-parameters.xml");
print(os.date("-- Generated on %Y-%m-%d"))

local registry_mapping = {
	["dns-parameters-2"] = "classes";
	["dns-parameters-4"] = "types";
	["dns-parameters-6"] = "errors";
};

print("return {");
for registry in registries:childtags("registry") do
	local registry_name = registry_mapping[registry.attr.id];
	if registry_name then
		print("\t" .. registry_name .. " = {");
		local duplicates = {};
		for record in registry:childtags("record") do
			local record_name = record:get_child_text("name");
			local record_type = record:get_child_text("type");
			local record_desc = record:get_child_text("description");
			local record_code = tonumber(record:get_child_text("value"));

			if tostring(record):lower():match("reserved") or tostring(record):lower():match("unassigned") then
				record_code = nil;
			end

			if registry_name == "classes" and record_code then
				record_type = record_desc and record_desc:match("%((%w+)%)$")
				if record_type then
					print(("\t\t[%q] = %d; [%d] = %q;"):format(record_type, record_code, record_code, record_type))
				end
			elseif registry_name == "types" and record_type and record_code then
				print(("\t\t[%q] = %d; [%d] = %q;"):format(record_type, record_code, record_code, record_type))
			elseif registry_name == "errors" and record_code and record_name then
				local dup = duplicates[record_code] and "-- " or "";
				print(("\t\t%s[%d] = %q; [%q] = %q;"):format(dup, record_code, record_name, record_name, record_desc or record_name));
				duplicates[record_code] = true;
			end
		end
		print("\t};");
	end
end
print("};");
