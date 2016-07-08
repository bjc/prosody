cache = true
read_globals = { "prosody", "hosts", "import" }
globals = { "_M" }
allow_defined_top = true
module = true
unused_secondaries = false
codes = true
ignore = { "411/err", "421/err", "411/ok", "421/ok", "211/_ENV" }

files["plugins/"] = {
	ignore = { "122/module" };
}
files["tests/"] = {
	ignore = {
		"113/assert_equal",
		"113/assert_table",
		"113/assert_function",
		"113/assert_string",
		"113/assert_boolean",
		"113/assert_is",
		"113/assert_is_not",
	};
}
