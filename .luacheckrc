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
