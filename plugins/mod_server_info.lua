local dataforms = require "prosody.util.dataforms";

local server_info_config = module:get_option("server_info", {});
local server_info_custom_fields = module:get_option_array("server_info_extensions");

-- Source: http://xmpp.org/registrar/formtypes.html#http:--jabber.org-network-serverinfo
local form_layout = dataforms.new({
	{ var = "FORM_TYPE"; type = "hidden"; value = "http://jabber.org/network/serverinfo" };
});

if server_info_custom_fields then
	for _, field in ipairs(server_info_custom_fields) do
		table.insert(form_layout, field);
	end
end

local generated_form;

function update_form()
	local new_form = form_layout:form(server_info_config, "result");
	if generated_form then
		module:remove_item("extension", generated_form);
	end
	generated_form = new_form;
	module:add_item("extension", generated_form);
end

function add_fields(event)
	local fields = event.item;
	for _, field in ipairs(fields) do
		table.insert(form_layout, field);
	end
	update_form();
end

function remove_fields(event)
	local removed_fields = event.item;
	for _, removed_field in ipairs(removed_fields) do
		local removed_var = removed_field.var or removed_field.name;
		for i, field in ipairs(form_layout) do
			local var = field.var or field.name
			if var == removed_var then
				table.remove(form_layout, i);
				break;
			end
		end
	end
	update_form();
end

module:handle_items("server-info-fields", add_fields, remove_fields);

function module.load()
	update_form();
end
