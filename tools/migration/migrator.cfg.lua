local data_path = "../../data";

local vhost = {
	"accounts",
	"account_details",
	"roster",
	"vcard",
	"private",
	"blocklist",
	"privacy",
	"archive-archive",
	"offline-archive",
	"pubsub_nodes-pubsub",
	"pep-pubsub",
}
local muc = {
	"persistent",
	"config",
	"state",
	"muc_log-archive",
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
