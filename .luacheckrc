cache = true
codes = true
ignore = { "411/err", "421/err", "411/ok", "421/ok", "211/_ENV", "431/log", }

std = "lua53c"
max_line_length = 150

read_globals = {
	"prosody",
	"import",
};
files["prosody"] = {
	allow_defined_top = true;
	module = true;
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

		-- Module API
		"module.add_extension",
		"module.add_feature",
		"module.add_identity",
		"module.add_item",
		"module.add_timer",
		"module.broadcast",
		"module.context",
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
		"module.get_option_inherited_set",
		"module.get_option_number",
		"module.get_option_path",
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
		"module.measure",
		"module.measure_event",
		"module.measure_global_event",
		"module.measure_object_event",
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
		"RunScript"
	};
}

if os.getenv("PROSODY_STRICT_LINT") ~= "1" then
	-- These files have not yet been brought up to standard
	-- Do not add more files here, but do help us fix these!
	unused_secondaries = false

	local exclude_files = {
		"doc/net.server.lua";

		"fallbacks/bit.lua";
		"fallbacks/lxp.lua";

		"net/cqueues.lua";
		"net/dns.lua";
		"net/server_select.lua";

		"plugins/mod_storage_sql1.lua";

		"spec/core_configmanager_spec.lua";
		"spec/core_moduleapi_spec.lua";
		"spec/net_http_parser_spec.lua";
		"spec/util_events_spec.lua";
		"spec/util_http_spec.lua";
		"spec/util_ip_spec.lua";
		"spec/util_multitable_spec.lua";
		"spec/util_rfc6724_spec.lua";
		"spec/util_throttle_spec.lua";
		"spec/util_xmppstream_spec.lua";

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
		"tools/xep227toprosody.lua";

		"util/sasl/digest-md5.lua";
	}
	for _, file in ipairs(exclude_files) do
		files[file] = { only = {} }
	end
end
