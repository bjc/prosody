
--[[

DB Tables:
	Prosody - key-value, map
		| host | user | store | key | subkey | type | value |
	ProsodyArchive - list
		| host | user | store | key | time | stanzatype | jsonvalue |

Mapping:
	Roster - Prosody
		| host | user | "roster" | "contactjid" | item-subkey | type | value |
		| host | user | "roster" | NULL | NULL | "json" | roster[false] data |
	Account - Prosody
		| host | user | "accounts" | "username" | NULL | type | value |

	Offline - ProsodyArchive
		| host | user | "offline" | "contactjid" | time | "message" | json|XML |

]]

local type = type;
local tostring = tostring;
local tonumber = tonumber;
local pairs = pairs;
local next = next;
local setmetatable = setmetatable;
local json = { stringify = function(s) return require"util.serialzation".serialize(s) end, parse = require"util.serialization".deserialze };

local connection = ...;
local host,user,store = module.host;

do -- process options to get a db connection
	local DBI = require "DBI";

	local params = module:get_option("sql");
	assert(params and params.driver and params.database, "invalid params");
	
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
end

local function serialize(value)
	local t = type(value);
	if t == "string" or t == "boolean" or t == "number" then
		return t, tostring(value);
	elseif t == "table" then
		local value,err = json.stringify(value);
		if value then return "json", value; end
		return nil, err;
	end
	return nil, "Unhandled value type: "..t;
end
local function deserialize(t, value)
	if t == "string" then return t;
	elseif t == "boolean" then
		if value == "true" then return true;
		elseif value == "false" then return false; end
	elseif t == "number" then return tonumber(value);
	elseif value == "json" then
		return json.parse(value);
	end
end

local function getsql(sql, ...)
	-- do prepared statement stuff
	local stmt, err = connection:prepare(sql);
	if not stmt then return nil, err; end
	-- run query
	local ok, err = stmt:execute(host, user, store, ...);
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
	local stmt, err = getsql("SELECT * FROM Prosody WHERE host=? AND user=? AND store=? AND subkey=NULL");
	if not stmt then return nil, err; end
	
	local haveany;
	local result = {};
	for row in stmt:rows(true) do
		haveany = true;
		local k = row.key;
		local v = deserialize(row.type, row.value);
		if v then
			if k then result[k] = v; elseif type(v) == "table" then
				for a,b in pairs(v) do
					result[a] = b;
				end
			end
		end
	end
	return haveany and result or nil;
end
function keyval_store:set(username, data)
	user,store = username,self.store;
	-- start transaction
	local affected, err = setsql("DELETE FROM Prosody WHERE host=? AND user=? AND store=? AND subkey=NULL");
	
	if data and next(data) ~= nil then
		local extradata = {};
		for key, value in pairs(data) do
			if type(key) == "string" then
				local t, value = serialize(value);
				if not t then return rollback(t, value); end
				local ok, err = setsql("INSERT INTO Prosody (host,user,store,key,type,value) VALUES (?,?,?,?,?,?)", key, t, value);
				if not ok then return rollback(ok, err); end
			else
				extradata[key] = value;
			end
		end
		if next(extradata) ~= nil then
			local t, extradata = serialize(extradata);
			if not t then return rollback(t, extradata); end
			local ok, err = setsql("INSERT INTO Prosody (host,user,store,key,type,value) VALUES (?,?,?,?,?,?)", nil, t, extradata);
			if not ok then return rollback(ok, err); end
		end
	end
	return commit(true);
end

local map_store = {};
map_store.__index = map_store;
function map_store:get(username, key)
	user,store = username,self.store;
	local stmt, err = getsql("SELECT * FROM Prosody WHERE host=? AND user=? AND store=? AND key=?", key);
	if not stmt then return nil, err; end
	
	local haveany;
	local result = {};
	for row in stmt:rows(true) do
		haveany = true;
		local k = row.subkey;
		local v = deserialize(row.type, row.value);
		if v then
			if k then result[k] = v; elseif type(v) == "table" then
				for a,b in pairs(v) do
					result[a] = b;
				end
			end
		end
	end
	return haveany and result or nil;
end
function map_store:set(username, key, data)
	user,store = username,self.store;
	-- start transaction
	local affected, err = setsql("DELETE FROM Prosody WHERE host=? AND user=? AND store=? AND key=?", key);
	
	if data and next(data) ~= nil then
		local extradata = {};
		for subkey, value in pairs(data) do
			if type(subkey) == "string" then
				local t, value = serialize(value);
				if not t then return rollback(t, value); end
				local ok, err = setsql("INSERT INTO Prosody (host,user,store,key,subkey,type,value) VALUES (?,?,?,?,?,?)", key, subkey, t, value);
				if not ok then return rollback(ok, err); end
			else
				extradata[subkey] = value;
			end
		end
		if next(extradata) ~= nil then
			local t, extradata = serialize(extradata);
			if not t then return rollback(t, extradata); end
			local ok, err = setsql("INSERT INTO Prosody (host,user,store,key,subkey,type,value) VALUES (?,?,?,?,?,?)", key, nil, t, extradata);
			if not ok then return rollback(ok, err); end
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
	local query = "SELECT * FROM ProsodyArchive WHERE host=? AND user=? AND store=?";
	
	query = query.." ORDER BY time";
	--local stmt, err = getsql("SELECT * FROM Prosody WHERE host=? AND user=? AND store=? AND key=?", key);
	
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
