-- XEP-0157: Contact Addresses for XMPP Services for Prosody
--
-- Copyright (C) 2011-2016 Kim Alvefur
--
-- This file is MIT/X11 licensed.
--

local t_insert = table.insert;
local array = require "util.array";
local df_new = require "util.dataforms".new;

-- Source: http://xmpp.org/registrar/formtypes.html#http:--jabber.org-network-serverinfo
local valid_types = {
	abuse = true;
	admin = true;
	feedback = true;
	sales = true;
	security = true;
	support = true;
}

local contact_config = module:get_option("contact_info");
if not contact_config or not next(contact_config) then -- we'll use admins from the config as default
	local admins = module:get_option_inherited_set("admins", {});
	if admins:empty() then
		module:log("error", "No contact_info or admins set in config");
		return -- Nothing to attach, so we'll just skip it.
	end
	module:log("info", "No contact_info in config, using admins as fallback");
	contact_config = {
		admin = array.collect( admins / function(admin) return "xmpp:" .. admin; end);
	};
end

local form_layout = {
	{ value = "http://jabber.org/network/serverinfo"; type = "hidden"; name = "FORM_TYPE"; };
};

local form_values = {};

for t in pairs(valid_types) do
	local addresses = contact_config[t];
	if addresses then
		t_insert(form_layout, { name = t .. "-addresses", type = "list-multi" });
		form_values[t .. "-addresses"] = addresses;
	end
end

module:add_extension(df_new(form_layout):form(form_values, "result"));
