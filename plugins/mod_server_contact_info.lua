-- XEP-0157: Contact Addresses for XMPP Services for Prosody
--
-- Copyright (C) 2011-2018 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local array = require "prosody.util.array";
local it = require "prosody.util.iterators";
local jid = require "prosody.util.jid";
local url = require "socket.url";

module:depends("server_info");

-- Source: http://xmpp.org/registrar/formtypes.html#http:--jabber.org-network-serverinfo
local address_types = {
	abuse = "abuse-addresses";
	admin = "admin-addresses";
	feedback = "feedback-addresses";
	sales = "sales-addresses";
	security = "security-addresses";
	status = "status-addresses";
	support = "support-addresses";
};

-- JIDs of configured service admins are used as fallback
local admins = module:get_option_inherited_set("admins", {});

local contact_config = module:get_option("contact_info", {
	admin = array.collect(admins / jid.prep / function(admin) return url.build({scheme = "xmpp"; path = admin}); end);
});

local fields = {};

for key, field_var in it.sorted_pairs(address_types) do
	if contact_config[key] then
		table.insert(fields, {
			type = "list-multi";
			name = key;
			var = field_var;
			value = contact_config[key];
		});
	end
end

module:add_item("server-info-fields", fields);
