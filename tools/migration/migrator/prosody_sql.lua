
local assert = assert;
local have_DBI, DBI = pcall(require,"DBI");
local print = print;
local type = type;
local next = next;
local pairs = pairs;
local t_sort = table.sort;
local json = require "util.json";
local mtools = require "migrator.mtools";
local tostring = tostring;
local tonumber = tonumber;

if not have_DBI then
	error("LuaDBI (required for SQL support) was not found, please see http://prosody.im/doc/depends#luadbi", 0);
end


local function create_table(connection, params)
	local create_sql = "CREATE TABLE `prosody` (`host` TEXT, `user` TEXT, `store` TEXT, `key` TEXT, `type` TEXT, `value` TEXT);";
	if params.driver == "PostgreSQL" then
		create_sql = create_sql:gsub("`", "\"");
	elseif params.driver == "MySQL" then
		create_sql = create_sql:gsub("`value` TEXT", "`value` MEDIUMTEXT");
	end

	local stmt = connection:prepare(create_sql);
	if stmt then
		local ok = stmt:execute();
		local commit_ok = connection:commit();
		if ok and commit_ok then
			local index_sql = "CREATE INDEX `prosody_index` ON `prosody` (`host`, `user`, `store`, `key`)";
			if params.driver == "PostgreSQL" then
				index_sql = index_sql:gsub("`", "\"");
			elseif params.driver == "MySQL" then
				index_sql = index_sql:gsub("`([,)])", "`(20)%1");
			end
			local stmt, err = connection:prepare(index_sql);
			local ok, commit_ok, commit_err;
			if stmt then
				ok, err = assert(stmt:execute());
				commit_ok, commit_err = assert(connection:commit());
			end
		elseif params.driver == "MySQL" then -- COMPAT: Upgrade tables from 0.8.0
			-- Failed to create, but check existing MySQL table here
			local stmt = connection:prepare("SHOW COLUMNS FROM prosody WHERE Field='value' and Type='text'");
			local ok = stmt:execute();
			local commit_ok = connection:commit();
			if ok and commit_ok then
				if stmt:rowcount() > 0 then
					local stmt = connection:prepare("ALTER TABLE prosody MODIFY COLUMN `value` MEDIUMTEXT");
					local ok = stmt:execute();
					local commit_ok = connection:commit();
					if ok and commit_ok then
						print("Database table automatically upgraded");
					end
				end
				repeat until not stmt:fetch();
			end
		end
	end
end

local function serialize(value)
	local t = type(value);
	if t == "string" or t == "boolean" or t == "number" then
		return t, tostring(value);
	elseif t == "table" then
		local value,err = json.encode(value);
		if value then return "json", value; end
		return nil, err;
	end
	return nil, "Unhandled value type: "..t;
end
local function deserialize(t, value)
	if t == "string" then return value;
	elseif t == "boolean" then
		if value == "true" then return true;
		elseif value == "false" then return false; end
	elseif t == "number" then return tonumber(value);
	elseif t == "json" then
		return json.decode(value);
	end
end

local function decode_user(item)
	local userdata = {
		user = item[1][1].user;
		host = item[1][1].host;
		stores = {};
	};
	for i=1,#item do -- loop over stores
		local result = {};
		local store = item[i];
		for i=1,#store do -- loop over store data
			local row = store[i];
			local k = row.key;
			local v = deserialize(row.type, row.value);
			if k and v then
				if k ~= "" then result[k] = v; elseif type(v) == "table" then
					for a,b in pairs(v) do
						result[a] = b;
					end
				end
			end
			userdata.stores[store[1].store] = result;
		end
	end
	return userdata;
end

local function reader(input)
	local dbh = assert(DBI.Connect(
		assert(input.driver, "no input.driver specified"),
		assert(input.database, "no input.database specified"),
		input.username, input.password,
		input.host, input.port
	));
	assert(dbh:ping());
	local stmt = assert(dbh:prepare("SELECT * FROM prosody"));
	assert(stmt:execute());
	local keys = {"host", "user", "store", "key", "type", "value"};
	local f,s,val = stmt:rows(true);
	-- get SQL rows, sorted
	local iter = mtools.sorted {
		reader = function() val = f(s, val); return val; end;
		filter = function(x)
			for i=1,#keys do
				if not x[keys[i]] then return false; end -- TODO log error, missing field
			end
			if x.host  == "" then x.host  = nil; end
			if x.user  == "" then x.user  = nil; end
			if x.store == "" then x.store = nil; end
			return x;
		end;
		sorter = function(a, b)
			local a_host, a_user, a_store = a.host or "", a.user or "", a.store or "";
			local b_host, b_user, b_store = b.host or "", b.user or "", b.store or "";
			return a_host > b_host or (a_host==b_host and a_user > b_user) or (a_host==b_host and a_user==b_user and a_store > b_store);
		end;
	};
	-- merge rows to get stores
	iter = mtools.merged(iter, function(a, b)
		return (a.host == b.host and a.user == b.user and a.store == b.store);
	end);
	-- merge stores to get users
	iter = mtools.merged(iter, function(a, b)
		return (a[1].host == b[1].host and a[1].user == b[1].user);
	end);
	return function()
		local x = iter();
		return x and decode_user(x);
	end;
end

local function writer(output, iter)
	local dbh = assert(DBI.Connect(
		assert(output.driver, "no output.driver specified"),
		assert(output.database, "no output.database specified"),
		output.username, output.password,
		output.host, output.port
	));
	assert(dbh:ping());
	create_table(dbh, output);
	local stmt = assert(dbh:prepare("SELECT * FROM prosody"));
	assert(stmt:execute());
	local stmt = assert(dbh:prepare("DELETE FROM prosody"));
	assert(stmt:execute());
	local insert_sql = "INSERT INTO `prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)";
	if output.driver == "PostgreSQL" then
		insert_sql = insert_sql:gsub("`", "\"");
	end
	local insert = assert(dbh:prepare(insert_sql));

	return function(item)
		if not item then assert(dbh:commit()) return dbh:close(); end -- end of input
		local host = item.host or "";
		local user = item.user or "";
		for store, data in pairs(item.stores) do
			-- TODO transactions
			local extradata = {};
			for key, value in pairs(data) do
				if type(key) == "string" and key ~= "" then
					local t, value = assert(serialize(value));
					local ok, err = assert(insert:execute(host, user, store, key, t, value));
				else
					extradata[key] = value;
				end
			end
			if next(extradata) ~= nil then
				local t, extradata = assert(serialize(extradata));
				local ok, err = assert(insert:execute(host, user, store, "", t, extradata));
			end
		end
	end;
end


return {
	reader = reader;
	writer = writer;
}
