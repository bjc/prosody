-- XEP-0157: Contact Addresses for XMPP Services for Prosody
--
-- Copyright (C) 2011-2018 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local array = require "util.array";

-- Source: http://xmpp.org/registrar/formtypes.html#http:--jabber.org-network-serverinfo
local form_layout = require "util.dataforms".new({
	{ var = "FORM_TYPE"; type = "hidden"; value = "http://jabber.org/network/serverinfo"; };
	{ name = "abuse", var = "abuse-addresses", type = "list-multi" },
	{ name = "admin", var = "admin-addresses", type = "list-multi" },
	{ name = "feedback", var = "feedback-addresses", type = "list-multi" },
	{ name = "sales", var = "sales-addresses", type = "list-multi" },
	{ name = "security", var = "security-addresses", type = "list-multi" },
	{ name = "status", var = "status-addresses", type = "list-multi" },
	{ name = "support", var = "support-addresses", type = "list-multi" },
});

-- JIDs of configured service admins are used as fallback
local admins = module:get_option_inherited_set("admins", {});

local contact_config = module:get_option("contact_info", {
	admin = array.collect( admins / function(admin) return "xmpp:" .. admin; end);
});

module:add_extension(form_layout:form(contact_config, "result"));
