-- Read an XML dataform and spit out a serialized Lua table of it

local function from_stanza(stanza)
	local layout = {
		title = stanza:get_child_text("title");
		instructions = stanza:get_child_text("instructions");
	};
	for tag in stanza:childtags("field") do
		local field = {
			name = tag.attr.var;
			type = tag.attr.type;
			label = tag.attr.label;
			desc = tag:get_child_text("desc");
			required = tag:get_child("required") and true or nil;
			value = tag:get_child_text("value");
			options = nil;
		};

		if field.type == "list-single" or field.type == "list-multi" then
			local options = {};
			for option in tag:childtags("option") do
				options[#options+1] = { label = option.attr.label, value = option:get_child_text("value") };
			end
			field.options = options;
		end

		if field.type == "jid-multi" or field.type == "list-multi" or field.type == "text-multi" then
			local values = {};
			for value in tag:childtags("value") do
				values[#values+1] = value:get_text();
			end
			if field.type == "text-multi" then
				values = table.concat(values, "\n");
			end
			field.value = values;
		end

		if field.type == "boolean" then
			field.value = field.value == "true" or field.value == "1";
		end

		layout[#layout+1] = field;

	end
	return layout;
end

print("dataforms.new " .. require "util.serialization".serialize(from_stanza(require "util.xml".parse(io.read("*a"))), { unquoted = true }))
