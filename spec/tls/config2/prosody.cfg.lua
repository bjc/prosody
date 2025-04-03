Include "prosody-default.cfg.lua"

VirtualHost "example.com"
	enabled = true
	modules_enabled = { "http" }
	http_host = "xmpp.example.com"
