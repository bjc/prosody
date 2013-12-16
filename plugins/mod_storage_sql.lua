
--[[

DB Tables:
	Prosody - key-value, map
		| host | user | store | key | type | value |
	ProsodyArchive - list
		| host | user | store | key | time | stanzatype | jsonvalue |

Mapping:
	Roster - Prosody
		| host | user | "roster" | "contactjid" | type | value |
		| host | user | "roster" | NULL | "json" | roster[false] data |
	Account - Prosody
		| host | user | "accounts" | "username" | type | value |

	Offline - ProsodyArchive
		| host | user | "offline" | "contactjid" | time | "message" | json|XML |

]]

local type = type;
local tostring = tostring;
local tonumber = tonumber;
local pairs = pairs;
local next = next;
local setmetatable = setmetatable;
local xpcall = xpcall;
local json = require "util.json";
local build_url = require"socket.url".build;

local DBI;
local connection;
local host,user,store = module.host;
local params = module:get_option("sql");

local dburi;
local connections = module:shared "/*/sql/connection-cache";

local function db2uri(params)
	return build_url{
		scheme = params.driver,
		user = params.username,
		password = params.password,
		host = params.host,
		port = params.port,
		path = params.database,
	};
end


local resolve_relative_path = require "core.configmanager".resolve_relative_path;

local function test_connection()
	if not connection then return nil; end
	if connection:ping() then
		return true;
	else
		module:log("debug", "Database connection closed");
		connection = nil;
		connections[dburi] = nil;
	end
end
local function connect()
	if not test_connection() then
		prosody.unlock_globals();
		local dbh, err = DBI.Connect(
			params.driver, params.database,
			params.username, params.password,
			params.host, params.port
		);
		prosody.lock_globals();
		if not dbh then
			module:log("debug", "Database connection failed: %s", tostring(err));
			return nil, err;
		end
		module:log("debug", "Successfully connected to database");
		dbh:autocommit(false); -- don't commit automatically
		connection = dbh;

		connections[dburi] = dbh;
	end
	return connection;
end

local function create_table()
	if not module:get_option("sql_manage_tables", true) then
		return;
	end
	local create_sql = "CREATE TABLE `prosody` (`host` TEXT, `user` TEXT, `store` TEXT, `key` TEXT, `type` TEXT, `value` TEXT);";
	if params.driver == "PostgreSQL" then
		create_sql = create_sql:gsub("`", "\"");
	elseif params.driver == "MySQL" then
		create_sql = create_sql:gsub("`value` TEXT", "`value` MEDIUMTEXT");
	end

	local stmt, err = connection:prepare(create_sql);
	if stmt then
		local ok = stmt:execute();
		local commit_ok = connection:commit();
		if ok and commit_ok then
			module:log("info", "Initialized new %s database with prosody table", params.driver);
			local index_sql = "CREATE INDEX `prosody_index` ON `prosody` (`host`, `user`, `store`, `key`)";
			if params.driver == "PostgreSQL" then
				index_sql = index_sql:gsub("`", "\"");
			elseif params.driver == "MySQL" then
				index_sql = index_sql:gsub("`([,)])", "`(20)%1");
			end
			local stmt, err = connection:prepare(index_sql);
			local ok, commit_ok, commit_err;
			if stmt then
				ok, err = stmt:execute();
				commit_ok, commit_err = connection:commit();
			end
			if not(ok and commit_ok) then
				module:log("warn", "Failed to create index (%s), lookups may not be optimised", err or commit_err);
			end
		elseif params.driver == "MySQL" then  -- COMPAT: Upgrade tables from 0.8.0
			-- Failed to create, but check existing MySQL table here
			local stmt = connection:prepare("SHOW COLUMNS FROM prosody WHERE Field='value' and Type='text'");
			local ok = stmt:execute();
			local commit_ok = connection:commit();
			if ok and commit_ok then
				if stmt:rowcount() > 0 then
					module:log("info", "Upgrading database schema...");
					local stmt = connection:prepare("ALTER TABLE prosody MODIFY COLUMN `value` MEDIUMTEXT");
					local ok, err = stmt:execute();
					local commit_ok = connection:commit();
					if ok and commit_ok then
						module:log("info", "Database table automatically upgraded");
					else
						module:log("error", "Failed to upgrade database schema (%s), please see "
							.."http://prosody.im/doc/mysql for help",
							err or "unknown error");
					end
				end
				repeat until not stmt:fetch();
			end
		end
	elseif params.driver ~= "SQLite3" then -- SQLite normally fails to prepare for existing table
		module:log("warn", "Prosody was not able to automatically check/create the database table (%s), "
			.."see http://prosody.im/doc/modules/mod_storage_sql#table_management for help.",
			err or "unknown error");
	end
end

do -- process options to get a db connection
	local ok;
	prosody.unlock_globals();
	ok, DBI = pcall(require, "DBI");
	if not ok then
		package.loaded["DBI"] = {};
		module:log("error", "Failed to load the LuaDBI library for accessing SQL databases: %s", DBI);
		module:log("error", "More information on installing LuaDBI can be found at http://prosody.im/doc/depends#luadbi");
	end
	prosody.lock_globals();
	if not ok or not DBI.Connect then
		return; -- Halt loading of this module
	end

	params = params or { driver = "SQLite3" };

	if params.driver == "SQLite3" then
		params.database = resolve_relative_path(prosody.paths.data or ".", params.database or "prosody.sqlite");
	end

	assert(params.driver and params.database, "Both the SQL driver and the database need to be specified");

	dburi = db2uri(params);
	connection = connections[dburi];

	assert(connect());

	-- Automatically create table, ignore failure (table probably already exists)
	create_table();
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

local function dosql(sql, ...)
	if params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
	-- do prepared statement stuff
	local stmt, err = connection:prepare(sql);
	if not stmt and not test_connection() then error("connection failed"); end
	if not stmt then module:log("error", "QUERY FAILED: %s %s", err, debug.traceback()); return nil, err; end
	-- run query
	local ok, err = stmt:execute(...);
	if not ok and not test_connection() then error("connection failed"); end
	if not ok then return nil, err; end

	return stmt;
end
local function getsql(sql, ...)
	return dosql(sql, host or "", user or "", store or "", ...);
end
local function setsql(sql, ...)
	local stmt, err = getsql(sql, ...);
	if not stmt then return stmt, err; end
	return stmt:affected();
end
local function transact(...)
	-- ...
end
local function rollback(...)
	if connection then connection:rollback(); end -- FIXME check for rollback error?
	return ...;
end
local function commit(...)
	local success,err = connection:commit();
	if not success then return nil, "SQL commit failed: "..tostring(err); end
	return ...;
end

local function keyval_store_get()
	local stmt, err = getsql("SELECT * FROM `prosody` WHERE `host`=? AND `user`=? AND `store`=?");
	if not stmt then return rollback(nil, err); end

	local haveany;
	local result = {};
	for row in stmt:rows(true) do
		haveany = true;
		local k = row.key;
		local v = deserialize(row.type, row.value);
		if k and v then
			if k ~= "" then result[k] = v; elseif type(v) == "table" then
				for a,b in pairs(v) do
					result[a] = b;
				end
			end
		end
	end
	return commit(haveany and result or nil);
end
local function keyval_store_set(data)
	local affected, err = setsql("DELETE FROM `prosody` WHERE `host`=? AND `user`=? AND `store`=?");
	if not affected then return rollback(affected, err); end

	if data and next(data) ~= nil then
		local extradata = {};
		for key, value in pairs(data) do
			if type(key) == "string" and key ~= "" then
				local t, value = serialize(value);
				if not t then return rollback(t, value); end
				local ok, err = setsql("INSERT INTO `prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", key, t, value);
				if not ok then return rollback(ok, err); end
			else
				extradata[key] = value;
			end
		end
		if next(extradata) ~= nil then
			local t, extradata = serialize(extradata);
			if not t then return rollback(t, extradata); end
			local ok, err = setsql("INSERT INTO `prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", "", t, extradata);
			if not ok then return rollback(ok, err); end
		end
	end
	return commit(true);
end

local keyval_store = {};
keyval_store.__index = keyval_store;
function keyval_store:get(username)
	user,store = username,self.store;
	if not connection and not connect() then return nil, "Unable to connect to database"; end
	local success, ret, err = xpcall(keyval_store_get, debug.traceback);
	if not connection and connect() then
		success, ret, err = xpcall(keyval_store_get, debug.traceback);
	end
	if success then return ret, err; else return rollback(nil, ret); end
end
function keyval_store:set(username, data)
	user,store = username,self.store;
	if not connection and not connect() then return nil, "Unable to connect to database"; end
	local success, ret, err = xpcall(function() return keyval_store_set(data); end, debug.traceback);
	if not connection and connect() then
		success, ret, err = xpcall(function() return keyval_store_set(data); end, debug.traceback);
	end
	if success then return ret, err; else return rollback(nil, ret); end
end
function keyval_store:users()
	local stmt, err = dosql("SELECT DISTINCT `user` FROM `prosody` WHERE `host`=? AND `store`=?", host, self.store);
	if not stmt then
		return rollback(nil, err);
	end
	local next = stmt:rows();
	return commit(function()
		local row = next();
		return row and row[1];
	end);
end

local function map_store_get(key)
	local stmt, err = getsql("SELECT * FROM `prosody` WHERE `host`=? AND `user`=? AND `store`=? AND `key`=?", key or "");
	if not stmt then return rollback(nil, err); end

	local haveany;
	local result = {};
	for row in stmt:rows(true) do
		haveany = true;
		local k = row.key;
		local v = deserialize(row.type, row.value);
		if k and v then
			if k ~= "" then result[k] = v; elseif type(v) == "table" then
				for a,b in pairs(v) do
					result[a] = b;
				end
			end
		end
	end
	return commit(haveany and result[key] or nil);
end
local function map_store_set(key, data)
	local affected, err = setsql("DELETE FROM `prosody` WHERE `host`=? AND `user`=? AND `store`=? AND `key`=?", key or "");
	if not affected then return rollback(affected, err); end

	if data and next(data) ~= nil then
		if type(key) == "string" and key ~= "" then
			local t, value = serialize(data);
			if not t then return rollback(t, value); end
			local ok, err = setsql("INSERT INTO `prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", key, t, value);
			if not ok then return rollback(ok, err); end
		else
			-- TODO non-string keys
		end
	end
	return commit(true);
end

local map_store = {};
map_store.__index = map_store;
function map_store:get(username, key)
	user,store = username,self.store;
	local success, ret, err = xpcall(function() return map_store_get(key); end, debug.traceback);
	if success then return ret, err; else return rollback(nil, ret); end
end
function map_store:set(username, key, data)
	user,store = username,self.store;
	local success, ret, err = xpcall(function() return map_store_set(key, data); end, debug.traceback);
	if success then return ret, err; else return rollback(nil, ret); end
end

local list_store = {};
list_store.__index = list_store;
function list_store:scan(username, from, to, jid, typ)
	user,store = username,self.store;

	local cols = {"from", "to", "jid", "typ"};
	local vals = { from ,  to ,  jid ,  typ };
	local stmt, err;
	local query = "SELECT * FROM `prosodyarchive` WHERE `host`=? AND `user`=? AND `store`=?";

	query = query.." ORDER BY time";
	--local stmt, err = getsql("SELECT * FROM `prosody` WHERE `host`=? AND `user`=? AND `store`=? AND `key`=?", key or "");

	return nil, "not-implemented"
end

local driver = {};

function driver:open(store, typ)
	if not typ then -- default key-value store
		return setmetatable({ store = store }, keyval_store);
	end
	return nil, "unsupported-store";
end

function driver:stores(username)
	local sql = "SELECT DISTINCT `store` FROM `prosody` WHERE `host`=? AND `user`" ..
		(username == true and "!=?" or "=?");
	if username == true or not username then
		username = "";
	end
	local stmt, err = dosql(sql, host, username);
	if not stmt then
		return rollback(nil, err);
	end
	local next = stmt:rows();
	return commit(function()
		local row = next();
		return row and row[1];
	end);
end

function driver:purge(username)
	local stmt, err = dosql("DELETE FROM `prosody` WHERE `host`=? AND `user`=?", host, username);
	if not stmt then return rollback(stmt, err); end
	local changed, err = stmt:affected();
	if not changed then return rollback(changed, err); end
	return commit(true, changed);
end

module:provides("storage", driver);
