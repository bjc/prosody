input {
	type = "prosody_sql";
	driver = "SQLite3";
	database = "out.sqlite";
}
output {
	type = "prosody_files";
	path = "out";
}

--[[

input {
	path = "../../data";
	type = "prosody_files";
	driver = "SQLite3";
	database = "../../prosody.sqlite";
}
output {
	type = "prosody_sql";
	driver = "SQLite3";
	database = "out.sqlite";
	path = "out";
}

]]
