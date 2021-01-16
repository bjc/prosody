-- Prosody IM
-- Copyright (C) 2008-2017 Matthew Wild
-- Copyright (C) 2008-2017 Waqas Hussain
-- Copyright (C) 2011-2017 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- XEP-0313: Message Archive Management for Prosody
--
-- luacheck: ignore 122/prosody

local global_default_policy = module:get_option_enum("default_archive_policy", "always", "roster", "never", true, false);
local smart_enable = module:get_option_boolean("mam_smart_enable", false);

if global_default_policy == "always" then
	global_default_policy = true;
elseif global_default_policy == "never" then
	global_default_policy = false;
end

do
	-- luacheck: ignore 211/prefs_format
	local prefs_format = {
		[false] = "roster",
		-- default ::= true | false | "roster"
		-- true = always, false = never, nil = global default
		["romeo@montague.net"] = true, -- always
		["montague@montague.net"] = false, -- newer
	};
end

local sessions = prosody.hosts[module.host].sessions;
local archive_store = module:get_option_string("archive_store", "archive");
local prefs = module:open_store(archive_store .. "_prefs");

local function get_prefs(user, explicit)
	local user_sessions = sessions[user];
	local user_prefs = user_sessions and user_sessions.archive_prefs
	if not user_prefs then
		-- prefs not cached
		user_prefs = prefs:get(user);
		if not user_prefs then
			-- prefs not set
			if smart_enable and explicit then
				-- a mam-capable client was involved in this action, set defaults
				user_prefs = { [false] = global_default_policy };
				prefs:set(user, user_prefs);
			end
		end
		if user_sessions then
			-- cache settings if they originate from user action
			user_sessions.archive_prefs = user_prefs;
		end
		if not user_prefs then
			if smart_enable then
				-- not yet enabled, either explicitly or "smart"
				user_prefs = { [false] = false };
			else
				-- no explicit settings, return defaults
				user_prefs = { [false] = global_default_policy };
			end
		end
	end
	return user_prefs;
end

local function set_prefs(user, user_prefs)
	local user_sessions = sessions[user];
	if user_sessions then
		user_sessions.archive_prefs = user_prefs;
	end
	return prefs:set(user, user_prefs);
end

return {
	get = get_prefs,
	set = set_prefs,
}
