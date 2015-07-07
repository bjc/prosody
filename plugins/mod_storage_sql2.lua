
local json = require "util.json";
local sql = require "util.sql";
local xml_parse = require "util.xml".parse;
local uuid = require "util.uuid";
local resolve_relative_path = require "util.paths".resolve_relative_path;

local stanza_mt = require"util.stanza".stanza_mt;
local getmetatable = getmetatable;
local t_concat = table.concat;
local function is_stanza(x) return getmetatable(x) == stanza_mt; end

local noop = function() end
local unpack = unpack
local function iterator(result)
	return function(result_)
		local row = result_();
		if row ~= nil then
			return unpack(row);
		end
	end, result, nil;
end

local default_params = { driver = "SQLite3" };

local engine;

local function serialize(value)
	local t = type(value);
	if t == "string" or t == "boolean" or t == "number" then
		return t, tostring(value);
	elseif is_stanza(value) then
		return "xml", tostring(value);
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
	elseif t == "xml" then
		return xml_parse(value);
	end
end

local host = module.host;
local user, store;

local function keyval_store_get()
	local haveany;
	local result = {};
	for row in engine:select("SELECT `key`,`type`,`value` FROM `prosody` WHERE `host`=? AND `user`=? AND `store`=?", host, user or "", store) do
		haveany = true;
		local k = row[1];
		local v = deserialize(row[2], row[3]);
		if k and v then
			if k ~= "" then result[k] = v; elseif type(v) == "table" then
				for a,b in pairs(v) do
					result[a] = b;
				end
			end
		end
	end
	if haveany then
		return result;
	end
end
local function keyval_store_set(data)
	engine:delete("DELETE FROM `prosody` WHERE `host`=? AND `user`=? AND `store`=?", host, user or "", store);

	if data and next(data) ~= nil then
		local extradata = {};
		for key, value in pairs(data) do
			if type(key) == "string" and key ~= "" then
				local t, value = serialize(value);
				assert(t, value);
				engine:insert("INSERT INTO `prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", host, user or "", store, key, t, value);
			else
				extradata[key] = value;
			end
		end
		if next(extradata) ~= nil then
			local t, extradata = serialize(extradata);
			assert(t, extradata);
			engine:insert("INSERT INTO `prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)", host, user or "", store, "", t, extradata);
		end
	end
	return true;
end

--- Key/value store API (default store type)

local keyval_store = {};
keyval_store.__index = keyval_store;
function keyval_store:get(username)
	user, store = username, self.store;
	local ok, result = engine:transaction(keyval_store_get);
	if not ok then
		module:log("error", "Unable to read from database %s store for %s: %s", store, username or "<host>", result);
		return nil, result;
	end
	return result;	
end
function keyval_store:set(username, data)
	user,store = username,self.store;
	return engine:transaction(function()
		return keyval_store_set(data);
	end);
end
function keyval_store:users()
	local ok, result = engine:transaction(function()
		return engine:select("SELECT DISTINCT `user` FROM `prosody` WHERE `host`=? AND `store`=?", host, self.store);
	end);
	if not ok then return ok, result end
	return iterator(result);
end

--- Archive store API

local archive_store = {}
archive_store.caps = {
	total = true;
};
archive_store.__index = archive_store
function archive_store:append(username, key, value, when, with)
	if type(when) ~= "number" then
		when, with, value = value, when, with;
	end
	local user,store = username,self.store;
	return engine:transaction(function()
		if key then
			engine:delete("DELETE FROM `prosodyarchive` WHERE `host`=? AND `user`=? AND `store`=? AND `key`=?", host, user or "", store, key);
		else
			key = uuid.generate();
		end
		local t, value = serialize(value);
		engine:insert("INSERT INTO `prosodyarchive` (`host`, `user`, `store`, `when`, `with`, `key`, `type`, `value`) VALUES (?,?,?,?,?,?,?,?)", host, user or "", store, when, with, key, t, value);
		return key;
	end);
end

-- Helpers for building the WHERE clause
local function archive_where(query, args, where)
	-- Time range, inclusive
	if query.start then
		args[#args+1] = query.start
		where[#where+1] = "`when` >= ?"
	end

	if query["end"] then
		args[#args+1] = query["end"];
		if query.start then
			where[#where] = "`when` BETWEEN ? AND ?" -- is this inclusive?
		else
			where[#where+1] = "`when` <= ?"
		end
	end

	-- Related name
	if query.with then
		where[#where+1] = "`with` = ?";
		args[#args+1] = query.with
	end

	-- Unique id
	if query.key then
		where[#where+1] = "`key` = ?";
		args[#args+1] = query.key
	end
end
local function archive_where_id_range(query, args, where)
	local args_len = #args
	-- Before or after specific item, exclusive
	if query.after then  -- keys better be unique!
		where[#where+1] = "`sort_id` > (SELECT `sort_id` FROM `prosodyarchive` WHERE `key` = ? AND `host` = ? AND `user` = ? AND `store` = ? LIMIT 1)"
		args[args_len+1], args[args_len+2], args[args_len+3], args[args_len+4] = query.after, args[1], args[2], args[3];
		args_len = args_len + 4
	end
	if query.before then
		where[#where+1] = "`sort_id` < (SELECT `sort_id` FROM `prosodyarchive` WHERE `key` = ? AND `host` = ? AND `user` = ? AND `store` = ? LIMIT 1)"
		args[args_len+1], args[args_len+2], args[args_len+3], args[args_len+4] = query.before, args[1], args[2], args[3];
	end
end

function archive_store:find(username, query)
	query = query or {};
	local user,store = username,self.store;
	local total;
	local ok, result = engine:transaction(function()
		local sql_query = "SELECT `key`, `type`, `value`, `when`, `with` FROM `prosodyarchive` WHERE %s ORDER BY `sort_id` %s%s;";
		local args = { host, user or "", store, };
		local where = { "`host` = ?", "`user` = ?", "`store` = ?", };

		archive_where(query, args, where);

		-- Total matching
		if query.total then
			local stats = engine:select("SELECT COUNT(*) FROM `prosodyarchive` WHERE " .. t_concat(where, " AND "), unpack(args));
			if stats then
				local _total = stats()
				total = _total and _total[1];
			end
			if query.limit == 0 then -- Skip the real query
				return noop, total;
			end
		end

		archive_where_id_range(query, args, where);

		if query.limit then
			args[#args+1] = query.limit;
		end

		sql_query = sql_query:format(t_concat(where, " AND "), query.reverse and "DESC" or "ASC", query.limit and " LIMIT ?" or "");
		module:log("debug", sql_query);
		return engine:select(sql_query, unpack(args));
	end);
	if not ok then return ok, result end
	return function()
		local row = result();
		if row ~= nil then
			return row[1], deserialize(row[2], row[3]), row[4], row[5];
		end
	end, total;
end

function archive_store:delete(username, query)
	query = query or {};
	local user,store = username,self.store;
	return engine:transaction(function()
		local sql_query = "DELETE FROM `prosodyarchive` WHERE %s;";
		local args = { host, user or "", store, };
		local where = { "`host` = ?", "`user` = ?", "`store` = ?", };
		if user == true then
			table.remove(args, 2);
			table.remove(where, 2);
		end
		archive_where(query, args, where);
		archive_where_id_range(query, args, where);
		sql_query = sql_query:format(t_concat(where, " AND "));
		module:log("debug", sql_query);
		return engine:delete(sql_query, unpack(args));
	end);
end

local stores = {
	keyval = keyval_store;
	archive = archive_store;
};

--- Implement storage driver API

-- FIXME: Some of these operations need to operate on the archive store(s) too

local driver = {};

function driver:open(store, typ)
	local store_mt = stores[typ or "keyval"];
	if store_mt then
		return setmetatable({ store = store }, store_mt);
	end
	return nil, "unsupported-store";
end

function driver:stores(username)
	local query = "SELECT DISTINCT `store` FROM `prosody` WHERE `host`=? AND `user`" ..
		(username == true and "!=?" or "=?");
	if username == true or not username then
		username = "";
	end
	local ok, result = engine:transaction(function()
		return engine:select(query, host, username);
	end);
	if not ok then return ok, result end
	return iterator(result);
end

function driver:purge(username)
	return engine:transaction(function()
		local stmt,err = engine:delete("DELETE FROM `prosody` WHERE `host`=? AND `user`=?", host, username);
		return true, err;
	end);
end

--- Initialization


local function create_table(name)
	local Table, Column, Index = sql.Table, sql.Column, sql.Index;

	local ProsodyTable = Table {
		name= name or "prosody";
		Column { name="host", type="TEXT", nullable=false };
		Column { name="user", type="TEXT", nullable=false };
		Column { name="store", type="TEXT", nullable=false };
		Column { name="key", type="TEXT", nullable=false };
		Column { name="type", type="TEXT", nullable=false };
		Column { name="value", type="MEDIUMTEXT", nullable=false };
		Index { name="prosody_index", "host", "user", "store", "key" };
	};
	engine:transaction(function()
		ProsodyTable:create(engine);
	end);

	local ProsodyArchiveTable = Table {
		name="prosodyarchive";
		Column { name="sort_id", type="INTEGER", primary_key=true, auto_increment=true };
		Column { name="host", type="TEXT", nullable=false };
		Column { name="user", type="TEXT", nullable=false };
		Column { name="store", type="TEXT", nullable=false };
		Column { name="key", type="TEXT", nullable=false }; -- item id
		Column { name="when", type="INTEGER", nullable=false }; -- timestamp
		Column { name="with", type="TEXT", nullable=false }; -- related id
		Column { name="type", type="TEXT", nullable=false };
		Column { name="value", type="MEDIUMTEXT", nullable=false };
		Index { name="prosodyarchive_index", unique = true, "host", "user", "store", "key" };
	};
	engine:transaction(function()
		ProsodyArchiveTable:create(engine);
	end);
end

local function upgrade_table(params, apply_changes)
	local changes = false;
	if params.driver == "MySQL" then
		local success,err = engine:transaction(function()
			local result = engine:execute("SHOW COLUMNS FROM prosody WHERE Field='value' and Type='text'");
			if result:rowcount() > 0 then
				changes = true;
				if apply_changes then
					module:log("info", "Upgrading database schema...");
					engine:execute("ALTER TABLE prosody MODIFY COLUMN `value` MEDIUMTEXT");
					module:log("info", "Database table automatically upgraded");
				end
			end
			return true;
		end);
		if not success then
			module:log("error", "Failed to check/upgrade database schema (%s), please see "
				.."http://prosody.im/doc/mysql for help",
				err or "unknown error");
			return false;
		end

		-- COMPAT w/pre-0.10: Upgrade table to UTF-8 if not already
		local check_encoding_query = "SELECT `COLUMN_NAME`,`COLUMN_TYPE` FROM `information_schema`.`columns` WHERE `TABLE_NAME`='prosody' AND ( `CHARACTER_SET_NAME`!='utf8' OR `COLLATION_NAME`!='utf8_bin' );";
		success,err = engine:transaction(function()
			local result = engine:execute(check_encoding_query);
			local n_bad_columns = result:rowcount();
			if n_bad_columns > 0 then
				changes = true;
				if apply_changes then
					module:log("warn", "Found %d columns in prosody table requiring encoding change, updating now...", n_bad_columns);
					local fix_column_query1 = "ALTER TABLE `prosody` CHANGE `%s` `%s` BLOB;";
					local fix_column_query2 = "ALTER TABLE `prosody` CHANGE `%s` `%s` %s CHARACTER SET 'utf8' COLLATE 'utf8_bin';";
					for row in result:rows() do
						local column_name, column_type = unpack(row);
						engine:execute(fix_column_query1:format(column_name, column_name));
						engine:execute(fix_column_query2:format(column_name, column_name, column_type));
					end
					module:log("info", "Database encoding upgrade complete!");
				end
			end
		end);
		success,err = engine:transaction(function() return engine:execute(check_encoding_query); end);
		if not success then
			module:log("error", "Failed to check/upgrade database encoding: %s", err or "unknown error");
			return false;
		end
	end
end

local function normalize_params(params)
	if params.driver == "SQLite3" then
		params.database = resolve_relative_path(prosody.paths.data or ".", params.database or "prosody.sqlite");
	end
	assert(params.driver and params.database, "Configuration error: Both the SQL driver and the database need to be specified");
	return params;
end

function module.load()
	if prosody.prosodyctl then return; end
	local params = normalize_params(module:get_option("sql", default_params));
	engine = sql:create_engine(params, function (engine)
		if module:get_option("sql_manage_tables", true) then
			-- Automatically create table, ignore failure (table probably already exists)
			-- FIXME: we should check in information_schema, etc.
			create_table();
			-- Check whether the table needs upgrading
			if not upgrade_table(params, true) then
				module:log("error", "Old database format detected, and upgrade failed");
				return false, "database upgrade needed";
			end
		end
	end);

	module:provides("storage", driver);
end
