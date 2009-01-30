-- Prosody IM v0.3
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local m_random = math.random;
module "uuid"

function generate()
	return m_random(0, 99999999);
end

return _M;