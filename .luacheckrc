cache = true
read_globals = { "prosody", "hosts", "import" }
globals = { "_M" }
allow_defined_top = true
module = true
unused_secondaries = false
codes = true
ignore = { "411/err", "421/err", "411/ok", "421/ok", "211/_ENV", "431/log" }

max_line_length = 150

files["core/"] = {
	read_globals = { "prosody", "hosts" };
	globals = { "prosody.hosts.?", "hosts.?" };
}
files["plugins/"] = {
	read_globals = {
		-- Module instance
		"module.name",
		"module.host",
		"module._log",
		"module.log",
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
		"module.handle_items",
		"module.has_feature",
		"module.has_identity",
		"module.hook",
		"module.hook_global",
		"module.hook_object_event",
		"module.hook_tag",
		"module.load_resource",
		"module.measure",
		"module.measure_event",
		"module.measure_global_event",
		"module.measure_object_event",
		"module.open_store",
		"module.provides",
		"module.remove_item",
		"module.require",
		"module.send",
		"module.set_global",
		"module.shared",
		"module.unhook",
		"module.unhook_object_event",
		"module.wrap_event",
		"module.wrap_global",
		"module.wrap_object_event",
	};
	globals = {
		"_M",

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
	std = "+busted"
}
