local set = require "prosody.util.set";

return {
	available = set.new{
		-- mod_bookmarks bundled
		"mod_bookmarks";
		-- mod_server_info bundled
		"mod_server_info";
		-- mod_flags bundled
		"mod_flags";
		-- mod_cloud_notify bundled
		"mod_cloud_notify";
		-- mod_muc has built-in vcard support
		"muc_vcard";
		-- mod_http_altconnect bundled
		"http_altconnect";
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
		"getopt-interval";
		"getopt-period";
		"getopt-integer";

		-- new module.ready()
		"module-ready";

		-- SIGUSR1 and 2 events
		"signal-events";
	};
};
