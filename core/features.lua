local set = require "util.set";

return {
	available = set.new{
		-- mod_bookmarks bundled
		"mod_bookmarks";
		-- Roles, module.may and per-session authz
		"permissions";
	};
};
