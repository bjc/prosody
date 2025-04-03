cache = true
codes = true
ignore = { "411/err", "421/err", "411/ok", "421/ok", "211/_ENV", "431/log", "214", "581" }

std = "lua54c"
max_line_length = 150

read_globals = {
	"prosody",
	"import",
};
files["prosody"] = {
	allow_defined_top = true;
	module = true;
	globals = {
		"prosody";
	}
}
files["prosodyctl"] = {
	allow_defined_top = true;
	module = true;
};
files["core/"] = {
	globals = {
		"prosody.hosts.?",
	};
}
files["util/"] = {
	-- Ignore unwrapped license text
	max_comment_line_length = false;
}
files["util/jsonschema.lua"] = {
	ignore = { "211" };
}
files["util/datamapper.lua"] = {
	ignore = { "211" };
}
files["plugins/"] = {
	module = true;
	allow_defined_top = true;
	read_globals = {
		-- Module instance
		"module.name",
		"module.host",
		"module._log",
		"module.event_handlers",
		"module.reloading",
		"module.saved_state",
		"module.global",
		"module.path",
		"module.items",

		-- Module API
		"module.add_extension",
		"module.add_feature",
		"module.add_identity",
		"module.add_item",
		"module.add_timer",
		"module.weekly",
		"module.daily",
		"module.hourly",
		"module.broadcast",
		"module.context",
		"module.could",
		"module.default_permission",
		"module.default_permissions",
		"module.depends",
		"module.fire_event",
		"module.get_directory",
		"module.get_host",
		"module.get_host_items",
		"module.get_host_type",
		"module.get_name",
		"module.get_option",
		"module.get_option_array",
		"module.get_option_boolean",
		"module.get_option_enum",
		"module.get_option_inherited_set",
		"module.get_option_integer",
		"module.get_option_number",
		"module.get_option_path",
		"module.get_option_period",
		"module.get_option_scalar",
		"module.get_option_set",
		"module.get_option_string",
		"module.get_status",
		"module.handle_items",
		"module.hook",
		"module.hook_global",
		"module.hook_object_event",
		"module.hook_tag",
		"module.load_resource",
		"module.log",
		"module.log_status",
		"module.may",
		"module.measure",
		"module.metric",
		"module.on_ready",
		"module.open_store",
		"module.provides",
		"module.remove_item",
		"module.require",
		"module.send",
		"module.send_iq",
		"module.set_global",
		"module.set_status",
		"module.shared",
		"module.unhook",
		"module.unhook_object_event",
		"module.wrap_event",
		"module.wrap_global",
		"module.wrap_object_event",

		-- mod_http API
		"module.http_url",
	};
	globals = {
		-- Methods that can be set on module API
		"module.ready",
		"module.unload",
		"module.add_host",
		"module.load",
		"module.add_host",
		"module.save",
		"module.restore",
		"module.command",
		"module.environment",
	};
}
files["spec/"] = {
	std = "+busted";
	globals = { "randomize" };
}
files["spec/tls"] = {
	-- luacheck complains about the config files here,
	-- but we don't really care about them
	only = {};
}
files["prosody.cfg.lua"] = {
	ignore = { "131" };
	globals = {
		"Host",
		"host",
		"VirtualHost",
		"Component",
		"component",
		"Include",
		"include",
		"FileContents",
		"FileLine",
		"FileLines",
		"Credential",
		"RunScript"
	};
}

if os.getenv("PROSODY_STRICT_LINT") ~= "1" then
	-- These files have not yet been brought up to standard
	-- Do not add more files here, but do help us fix these!

	local exclude_files = {
		"doc/net.server.lua";

		"fallbacks/bit.lua";
		"fallbacks/lxp.lua";

		"net/dns.lua";
		"net/server_select.lua";

		"spec/core_moduleapi_spec.lua";
		"spec/util_http_spec.lua";
		"spec/util_ip_spec.lua";
		"spec/util_multitable_spec.lua";
		"spec/util_throttle_spec.lua";

		"tools/ejabberd2prosody.lua";
		"tools/ejabberdsql2prosody.lua";
		"tools/erlparse.lua";
		"tools/jabberd14sql2prosody.lua";
		"tools/migration/migrator.cfg.lua";
		"tools/migration/migrator/jabberd14.lua";
		"tools/migration/migrator/mtools.lua";
		"tools/migration/migrator/prosody_files.lua";
		"tools/migration/migrator/prosody_sql.lua";
		"tools/migration/prosody-migrator.lua";
		"tools/openfire2prosody.lua";
		"tools/test_mutants.sh.lua";
		"tools/xep227toprosody.lua";
	}
	for _, file in ipairs(exclude_files) do
		files[file] = { only = {} }
	end
end
