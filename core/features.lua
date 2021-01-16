local set = require "prosody.util.set";

return {
	available = set.new{
		-- mod_bookmarks bundled
		"mod_bookmarks";
		-- Roles, module.may and per-session authz
		"permissions";
		-- prosody.* namespace
		"loader";
		-- "keyval+" store
		"keyval+";

		"s2sout-pre-connect-event";

		-- prosody:guest, prosody:registered, prosody:member
		"split-user-roles";

		-- new moduleapi methods
		"getopt-enum";
	};
};
