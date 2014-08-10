-- Prosody IM
-- Copyright (C) 2009-2010 Matthew Wild
-- Copyright (C) 2009-2010 Waqas Hussain
-- Copyright (C) 2009 Thilo Cestonaro
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


-- COMPAT w/ pre 0.10
module:log("error", "The mod_privacy plugin has been replaced by mod_blocklist. Please update your config. For more information see https://prosody.im/doc/modules/mod_privacy");
module:depends("blocklist");
