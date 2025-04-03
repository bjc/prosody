Include "prosody-default.cfg.lua"

c2s_direct_tls_ports = { 5223 }

VirtualHost "example.com"
	enabled = true
	modules_enabled = { "http" }
	http_host = "xmpp.example.com"

VirtualHost "example.net"
	ssl = {
		certificate = "certs/example.com.crt";
		key = "certs/example.com.key";
	}

	https_ssl = {
		certificate = "certs/example.com.crt";
		key = "certs/example.com.key";
	}

	c2s_direct_tls_ssl = {
		certificate = "certs/example.com.crt";
		key = "certs/example.com.key";
	}

VirtualHost "example.org"
Component "share.example.org" "http_file_share"
Component "groups.example.org" "muc"
