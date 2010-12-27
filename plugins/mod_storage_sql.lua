
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
local json = require "util.json";

local connection = ...;
local host,user,store = module.host;
local params = module:get_option("sql");

do -- process options to get a db connection
	local DBI = require "DBI";

	params = params or { driver = "SQLite3", database = "prosody.sqlite" };
	assert(params.driver and params.database, "invalid params");
	
	prosody.unlock_globals();
	local dbh, err = DBI.Connect(
		params.driver, params.database,
		params.username, params.password,
		params.host, params.port
	);
	prosody.lock_globals();
	assert(dbh, err);

	dbh:autocommit(false); -- don't commit automatically
	connection = dbh;
	
	if params.driver == "SQLite3" then -- auto initialize
		local stmt = assert(connection:prepare("SELECT COUNT(*) FROM `sqlite_master` WHERE `type`='table' AND `name`='Prosody';"));
		local ok = assert(stmt:execute());
		local count = stmt:fetch()[1];
		if count == 0 then
			local stmt = assert(connection:prepare("CREATE TABLE `Prosody` (`host` TEXT, `user` TEXT, `store` TEXT, `key` TEXT, `type` TEXT, `value` TEXT);"));
			assert(stmt:execute());
			module:log("debug", "Initialized new SQLite3 database");
		end
		assert(connection:commit());
		--print("===", json.encode())
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

local function getsql(sql, ...)
	if params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
	-- do prepared statement stuff
	local stmt, err = connection:prepare(sql);
	if not stmt then module:log("error", "QUERY FAILED: %s %s", err, debug.traceback()); return nil, err; end
	-- run query
	local ok, err = stmt:execute(host or "", user or "", store or "", ...);
	if not ok then return nil, err; end
	
	return stmt;
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
	connection:rollback(); -- FIXME check for rollback error?
	return ...;
end
local function commit(...)
	if not connection:commit() then return nil, "SQL commit failed"; end
	return ...;
end

local keyval_store = {};
keyval_store.__index = keyval_store;
function keyval_store:get(username)
	user,store = username,self.store;
	local stmt, err = getsql("SELECT * FROM `Prosody` WHERE `host`=? AND `user`=? AND `store`=?");
	if not stmt then return nil, err; end
	
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
function keyval_store:set(username, data)
	user,store = username,self.store;
	-- start transaction
	local affected, err = setsql("DELETE FROM `Prosody` WHERE `host`=? AND `user`=? AND `store`=?");
	
	if data and next(data) ~= nil then
		local extradata = {};
		for key, value in pairs(data) do
			if type(key) == "string" and key ~= "" then
				local t, value = serialize(value);
				if not t then return rollback(t, value); end
				local ok, err = setsql("INSERT INTO `Prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", key, t, value);
				if not ok then return rollback(ok, err); end
			else
				extradata[key] = value;
			end
		end
		if next(extradata) ~= nil then
			local t, extradata = serialize(extradata);
			if not t then return rollback(t, extradata); end
			local ok, err = setsql("INSERT INTO `Prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", "", t, extradata);
			if not ok then return rollback(ok, err); end
		end
	end
	return commit(true);
end

local map_store = {};
map_store.__index = map_store;
function map_store:get(username, key)
	user,store = username,self.store;
	local stmt, err = getsql("SELECT * FROM `Prosody` WHERE `host`=? AND `user`=? AND `store`=? AND `key`=?", key or "");
	if not stmt then return nil, err; end
	
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
function map_store:set(username, key, data)
	user,store = username,self.store;
	-- start transaction
	local affected, err = setsql("DELETE FROM `Prosody` WHERE `host`=? AND `user`=? AND `store`=? AND `key`=?", key or "");
	
	if data and next(data) ~= nil then
		if type(key) == "string" and key ~= "" then
			local t, value = serialize(data);
			if not t then return rollback(t, value); end
			local ok, err = setsql("INSERT INTO `Prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", key, t, value);
			if not ok then return rollback(ok, err); end
		else
			-- TODO non-string keys
		end
	end
	return commit(true);
end

local list_store = {};
list_store.__index = list_store;
function list_store:scan(username, from, to, jid, typ)
	user,store = username,self.store;
	
	local cols = {"from", "to", "jid", "typ"};
	local vals = { from ,  to ,  jid ,  typ };
	local stmt, err;
	local query = "SELECT * FROM `ProsodyArchive` WHERE `host`=? AND `user`=? AND `store`=?";
	
	query = query.." ORDER BY time";
	--local stmt, err = getsql("SELECT * FROM `Prosody` WHERE `host`=? AND `user`=? AND `store`=? AND `key`=?", key or "");
	
	return nil, "not-implemented"
end

local driver = { name = "sql" };

function driver:open(store, typ)
	if not typ then -- default key-value store
		return setmetatable({ store = store }, keyval_store);
	end
	return nil, "unsupported-store";
end

module:add_item("data-driver", driver);
