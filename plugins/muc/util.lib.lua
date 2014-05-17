-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local _M = {};

_M.valid_affiliations = {
	outcast = -1;
	none = 0;
	member = 1;
	admin = 2;
	owner = 3;
};

_M.valid_roles = {
	none = 0;
	visitor = 1;
	participant = 2;
	moderator = 3;
};

local kickable_error_conditions = {
	["gone"] = true;
	["internal-server-error"] = true;
	["item-not-found"] = true;
	["jid-malformed"] = true;
	["recipient-unavailable"] = true;
	["redirect"] = true;
	["remote-server-not-found"] = true;
	["remote-server-timeout"] = true;
	["service-unavailable"] = true;
	["malformed error"] = true;
};
function _M.is_kickable_error(stanza)
	local cond = select(2, stanza:get_error()) or "malformed error";
	return kickable_error_conditions[cond];
end

return _M;
