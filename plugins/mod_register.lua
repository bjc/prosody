-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local allow_registration = module:get_option_boolean("allow_registration", false);

if allow_registration then
	module:depends("register_ibr");
	module:depends("watchregistrations");
end

module:depends("user_account_management");
