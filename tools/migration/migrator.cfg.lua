local data_path = "../../data";

local vhost = {
	"accounts",
	"account_details",
	"account_roles",
	"roster",
	"vcard",
	"private",
	"blocklist",
	"privacy",
	"archive-archive",
	"offline-archive",
	"pubsub_nodes-pubsub",
	"pep-pubsub",
	"cron",
	"smacks_h",
}
local muc = {
	"persistent",
	"config",
	"state",
	"muc_log-archive",
	"cron",
};

input {
	hosts = {
		["example.com"] = vhost;
		["conference.example.com"] = muc;
	};
	type = "internal";
	path = data_path;
}

output {
	type = "sql";
	driver = "SQLite3";
	database = data_path.."/prosody.sqlite";
}

--[[

input {
	type = "internal";
	path = data_path;
}
output {
	type = "sql";
	driver = "SQLite3";
	database = data_path.."/prosody.sqlite";
}

]]
