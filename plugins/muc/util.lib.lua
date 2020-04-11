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

local filtered_namespaces = module:shared("filtered-namespaces");
filtered_namespaces["http://jabber.org/protocol/muc"] = true;
filtered_namespaces["http://jabber.org/protocol/muc#user"] = true;

local function muc_ns_filter(tag)
	if filtered_namespaces[tag.attr.xmlns] then
		return nil;
	end
	return tag;
end
function _M.filter_muc_x(stanza)
	return stanza:maptags(muc_ns_filter);
end

function _M.add_filtered_namespace(xmlns)
	filtered_namespaces[xmlns] = true;
end

function _M.only_with_min_role(role)
	local min_role_value = _M.valid_roles[role];
	return function (nick, occupant) --luacheck: ignore 212/nick
		if _M.valid_roles[occupant.role or "none"] >= min_role_value then
			return true;
		end
	end;
end

return _M;
