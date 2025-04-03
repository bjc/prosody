Include "prosody-default.cfg.lua"

VirtualHost "example.com"
	enabled = true

Component "share.example.com" "http_file_share"
