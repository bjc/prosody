--luacheck: ignore

-- Mock time functions to simplify tests
function _G.os.time()
	return 1219439344;
end
package.preload["util.time"] = function ()
	return {
		now = function () return 1219439344.1; end;
		monotonic = function () return 0.1; end;
	}
end

admins = { "admin@localhost" }

use_libevent = true

modules_enabled = {
	-- Generally required
		"roster"; -- Allow users to have a roster. Recommended ;)
		"saslauth"; -- Authentication for clients and servers. Recommended if you want to log in.
		--"tls"; -- Add support for secure TLS on c2s/s2s connections
		--"dialback"; -- s2s dialback support
		"disco"; -- Service discovery

	-- Not essential, but recommended
		"carbons"; -- Keep multiple clients in sync
		"pep"; -- Enables users to publish their avatar, mood, activity, playing music and more
		"private"; -- Private XML storage (for room bookmarks, etc.)
		"blocklist"; -- Allow users to block communications with other users
		"vcard4"; -- User profiles (stored in PEP)
		"vcard_legacy"; -- Conversion between legacy vCard and PEP Avatar, vcard

	-- Nice to have
		"version"; -- Replies to server version requests
		"uptime"; -- Report how long server has been running
		"time"; -- Let others know the time here on this server
		"ping"; -- Replies to XMPP pings with pongs
		"register"; -- Allow users to register on this server using a client and change passwords
		"mam"; -- Store messages in an archive and allow users to access it
		--"csi_simple"; -- Simple Mobile optimizations

	-- Admin interfaces
		--"admin_adhoc"; -- Allows administration via an XMPP client that supports ad-hoc commands
		--"admin_telnet"; -- Opens telnet console interface on localhost port 5582

	-- HTTP modules
		--"bosh"; -- Enable BOSH clients, aka "Jabber over HTTP"
		--"websocket"; -- XMPP over WebSockets
		--"http_files"; -- Serve static files from a directory over HTTP

	-- Other specific functionality
		--"limits"; -- Enable bandwidth limiting for XMPP connections
		--"groups"; -- Shared roster support
		"server_contact_info"; -- Publish contact information for this service
		--"announce"; -- Send announcement to all online users
		--"welcome"; -- Welcome users who register accounts
		--"watchregistrations"; -- Alert admins of registrations
		--"motd"; -- Send a message to users when they log in
		--"legacyauth"; -- Legacy authentication. Only used by some old clients and bots.
		--"proxy65"; -- Enables a file transfer proxy service which clients behind NAT can use
		"lastactivity";

	-- Useful for testing
		--"scansion_record"; -- Records things that happen in scansion test case format
}

contact_info = {
	abuse = { "mailto:abuse@localhost", "xmpp:abuse@localhost" };
	admin = { "mailto:admin@localhost", "xmpp:admin@localhost" };
	feedback = { "http://localhost/feedback.html", "mailto:feedback@localhost", "xmpp:feedback@localhost" };
	sales = { "xmpp:sales@localhost" };
	security = { "xmpp:security@localhost" };
	support = { "https://localhost/support.html", "xmpp:support@localhost" };
}

modules_disabled = {
	"s2s";
}
certificate = "certs"

allow_registration = false

c2s_require_encryption = false
allow_unencrypted_plain_auth = true

authentication = "insecure"
insecure_open_authentication = "Yes please, I know what I'm doing!"

storage = "memory"

mam_smart_enable = true

-- For the "sql" backend, you can uncomment *one* of the below to configure:
--sql = { driver = "SQLite3", database = "prosody.sqlite" } -- Default. 'database' is the filename.
--sql = { driver = "MySQL", database = "prosody", username = "prosody", password = "secret", host = "localhost" }
--sql = { driver = "PostgreSQL", database = "prosody", username = "prosody", password = "secret", host = "localhost" }


-- Logging configuration
-- For advanced logging see https://prosody.im/doc/logging
log = "*console"

pidfile = "prosody.pid"

VirtualHost "localhost"

hide_os_type = true -- absense tested for in version.scs

Component "conference.localhost" "muc"
	storage = "memory"

Component "pubsub.localhost" "pubsub"
	storage = "memory"
