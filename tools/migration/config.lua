local data_path = "../../data";

input {
	type = "prosody_files";
	path = data_path;
}

output {
	type = "prosody_sql";
	driver = "SQLite3";
	database = data_path.."/prosody.sqlite";
}

--[[

input {
	type = "prosody_files";
	path = data_path;
}
output {
	type = "prosody_sql";
	driver = "SQLite3";
	database = data_path.."/prosody.sqlite";
}

]]
