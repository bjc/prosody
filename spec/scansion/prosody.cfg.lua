--luacheck: ignore

admins = { "admin@localhost" }

use_libevent = true

modules_enabled = {
	-- Generally required
		"roster"; -- Allow users to have a roster. Recommended ;)
		"saslauth"; -- Authentication for clients and servers. Recommended if you want to log in.
		"tls"; -- Add support for secure TLS on c2s/s2s connections
		"dialback"; -- s2s dialback support
		"disco"; -- Service discovery

	-- Not essential, but recommended
		"carbons"; -- Keep multiple clients in sync
		"pep"; -- Enables users to publish their mood, activity, playing music and more
		"private"; -- Private XML storage (for room bookmarks, etc.)
		"blocklist"; -- Allow users to block communications with other users
		"vcard"; -- Allow users to set vCards

	-- Nice to have
		"version"; -- Replies to server version requests
		"uptime"; -- Report how long server has been running
		"time"; -- Let others know the time here on this server
		"ping"; -- Replies to XMPP pings with pongs
		"register"; -- Allow users to register on this server using a client and change passwords
		--"mam"; -- Store messages in an archive and allow users to access it

	-- HTTP modules
		--"bosh"; -- Enable BOSH clients, aka "Jabber over HTTP"
		--"websocket"; -- XMPP over WebSockets
		--"http_files"; -- Serve static files from a directory over HTTP

	-- Other specific functionality
		--"limits"; -- Enable bandwidth limiting for XMPP connections
		--"groups"; -- Shared roster support
		--"server_contact_info"; -- Publish contact information for this service
		--"announce"; -- Send announcement to all online users
		--"welcome"; -- Welcome users who register accounts
		--"watchregistrations"; -- Alert admins of registrations
		--"motd"; -- Send a message to users when they log in
		--"legacyauth"; -- Legacy authentication. Only used by some old clients and bots.
		--"proxy65"; -- Enables a file transfer proxy service which clients behind NAT can use

	-- Useful for testing
		--"scansion_record"; -- Records things that happen in scansion test case format
}

certificate = "certs"

allow_registration = false

c2s_require_encryption = false
allow_unencrypted_plain_auth = true

authentication = "insecure"
insecure_open_authentication = "Yes please, I know what I'm doing!"

storage = "memory"


-- For the "sql" backend, you can uncomment *one* of the below to configure:
--sql = { driver = "SQLite3", database = "prosody.sqlite" } -- Default. 'database' is the filename.
--sql = { driver = "MySQL", database = "prosody", username = "prosody", password = "secret", host = "localhost" }
--sql = { driver = "PostgreSQL", database = "prosody", username = "prosody", password = "secret", host = "localhost" }


-- Logging configuration
-- For advanced logging see https://prosody.im/doc/logging
log = "*console"

daemonize = true
pidfile = "prosody.pid"

VirtualHost "localhost"

Component "conference.localhost" "muc"
	storage = "memory"

Component "pubsub.localhost" "pubsub"
	storage = "memory"
