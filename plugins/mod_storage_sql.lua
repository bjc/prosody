
-- luacheck: ignore 212/self

local cache = require "prosody.util.cache";
local json = require "prosody.util.json";
local xml_parse = require "prosody.util.xml".parse;
local uuid = require "prosody.util.uuid";
local resolve_relative_path = require "prosody.util.paths".resolve_relative_path;
local jid_join = require "prosody.util.jid".join;

local is_stanza = require"prosody.util.stanza".is_stanza;
local t_concat = table.concat;

local have_dbisql, dbisql = pcall(require, "prosody.util.sql");
local have_sqlite, sqlite = pcall(require, "prosody.util.sqlite3");
if not (have_dbisql or have_sqlite) then
	module:log("error", "LuaDBI or LuaSQLite3 are required for using SQL databases but neither are installed");
	module:log("error", "Please install at least one of LuaDBI and LuaSQLite3. See https://prosody.im/doc/depends");
	module:log("debug", "Could not load LuaDBI: %s", dbisql);
	module:log("debug", "Could not load LuaSQLite3: %s", sqlite);
	error("No SQL library available")
end

local function get_sql_lib(driver)
	if driver == "SQLite3" and have_sqlite then
		return sqlite;
	elseif have_dbisql then
		return dbisql;
	else
		error(dbisql);
	end
end

local noop = function() end
local unpack = table.unpack;
local function iterator(result)
	return function(result_)
		local row = result_();
		if row ~= nil then
			return unpack(row);
		end
	end, result, nil;
end

-- COMPAT Support for UPSERT is not in all versions of all compatible databases.
local function has_upsert(engine)
	if engine.params.driver == "SQLite3" then
		-- SQLite3 >= 3.24.0
		return engine.sqlite_version and (engine.sqlite_version[2] or 0) >= 24 and engine.has_upsert_index;
	elseif engine.params.driver == "PostgreSQL" then
		-- PostgreSQL >= 9.5
		-- Versions without support have long since reached end of life.
		return engine.has_upsert_index;
	end
	-- We don't support UPSERT on MySQL/MariaDB, they seem to have a completely different syntax, uncertaint from which versions.
	return false
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
		local encoded,err = json.encode(value);
		if encoded then return "json", encoded; end
		return nil, err;
	end
	return nil, "Unhandled value type: "..t;
end
local function deserialize(t, value)
	if t == "string" then return value;
	elseif t == "boolean" then
		if value == "true" then return true;
		elseif value == "false" then return false; end
		return nil, "invalid-boolean";
	elseif t == "number" then
		value = tonumber(value);
		if value then return value; end
		return nil, "invalid-number";
	elseif t == "json" then
		return json.decode(value);
	elseif t == "xml" then
		return xml_parse(value);
	end
	return nil, "Unhandled value type: "..t;
end

local host = module.host;

local function keyval_store_get(user, store)
	local haveany;
	local result = {};
	local select_sql = [[
	SELECT "key","type","value"
	FROM "prosody"
	WHERE "host"=? AND "user"=? AND "store"=?;
	]]
	for row in engine:select(select_sql, host, user or "", store) do
		haveany = true;
		local k = row[1];
		local v, e = deserialize(row[2], row[3]);
		assert(v ~= nil, e);
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
local function keyval_store_set(data, user, store)
	local delete_sql = [[
	DELETE FROM "prosody"
	WHERE "host"=? AND "user"=? AND "store"=?
	]];
	engine:delete(delete_sql, host, user or "", store);

	local insert_sql = [[
	INSERT INTO "prosody"
	("host","user","store","key","type","value")
	VALUES (?,?,?,?,?,?);
	]]
	if data and next(data) ~= nil then
		local extradata = {};
		for key, value in pairs(data) do
			if type(key) == "string" and key ~= "" then
				local t, encoded_value = assert(serialize(value));
				engine:insert(insert_sql, host, user or "", store, key, t, encoded_value);
			else
				extradata[key] = value;
			end
		end
		if next(extradata) ~= nil then
			local t, encoded_extradata = assert(serialize(extradata));
			engine:insert(insert_sql, host, user or "", store, "", t, encoded_extradata);
		end
	end
	return true;
end

--- Key/value store API (default store type)

local keyval_store = {};
keyval_store.__index = keyval_store;
function keyval_store:get(username)
	local ok, result = engine:transaction(keyval_store_get, username, self.store);
	if not ok then
		module:log("error", "Unable to read from database %s store for %s: %s", self.store, username or "<host>", result);
		return nil, result;
	end
	return result;
end
function keyval_store:set(username, data)
	return engine:transaction(keyval_store_set, data, username, self.store);
end
function keyval_store:users()
	local ok, result = engine:transaction(function()
		local select_sql = [[
		SELECT DISTINCT "user"
		FROM "prosody"
		WHERE "host"=? AND "store"=?;
		]];
		return engine:select(select_sql, host, self.store);
	end);
	if not ok then error(result); end
	return iterator(result);
end

--- Archive store API

local archive_item_limit = module:get_option_integer("storage_archive_item_limit", nil, 0);
local archive_item_count_cache = cache.new(module:get_option_integer("storage_archive_item_limit_cache_size", 1000, 1));

local item_count_cache_hit = module:measure("item_count_cache_hit", "rate");
local item_count_cache_miss = module:measure("item_count_cache_miss", "rate")

-- luacheck: ignore 512 431/user 431/store 431/err
local map_store = {};
map_store.__index = map_store;
map_store.remove = {};
function map_store:get(username, key)
	local ok, result = engine:transaction(function()
		local query = [[
		SELECT "type", "value"
		FROM "prosody"
		WHERE "host"=? AND "user"=? AND "store"=? AND "key"=?
		LIMIT 1
		]];
		local data, err;
		if type(key) == "string" and key ~= "" then
			for row in engine:select(query, host, username or "", self.store, key) do
				data, err = deserialize(row[1], row[2]);
				assert(data ~= nil, err);
			end
			return data;
		else
			for row in engine:select(query, host, username or "", self.store, "") do
				data, err = deserialize(row[1], row[2]);
				assert(data ~= nil, err);
			end
			return data and data[key] or nil;
		end
	end);
	if not ok then return nil, result; end
	return result;
end
function map_store:set(username, key, data)
	if data == nil then data = self.remove; end
	return self:set_keys(username, { [key] = data });
end
function map_store:set_keys(username, keydatas)
	local ok, result = engine:transaction(function()
		local delete_sql = [[
		DELETE FROM "prosody"
		WHERE "host"=? AND "user"=? AND "store"=? AND "key"=?;
		]];
		local insert_sql = [[
		INSERT INTO "prosody"
		("host","user","store","key","type","value")
		VALUES (?,?,?,?,?,?);
		]];
		local upsert_sql = [[
		INSERT INTO "prosody"
		("host","user","store","key","type","value")
		VALUES (?,?,?,?,?,?)
		ON CONFLICT ("host", "user","store", "key")
		DO UPDATE SET "type"=?, "value"=?;
		]];
		local select_extradata_sql = [[
		SELECT "type", "value"
		FROM "prosody"
		WHERE "host"=? AND "user"=? AND "store"=? AND "key"=?
		LIMIT 1;
		]];
		for key, data in pairs(keydatas) do
			if type(key) == "string" and key ~= "" and has_upsert(engine) and data ~= self.remove then
				local t, value = assert(serialize(data));
				engine:insert(upsert_sql, host, username or "", self.store, key, t, value, t, value);
			elseif type(key) == "string" and key ~= "" then
				engine:delete(delete_sql,
					host, username or "", self.store, key);
				if data ~= self.remove then
					local t, value = assert(serialize(data));
					engine:insert(insert_sql, host, username or "", self.store, key, t, value);
				end
			else
				local extradata, err = {};
				for row in engine:select(select_extradata_sql, host, username or "", self.store, "") do
					extradata, err = deserialize(row[1], row[2]);
					assert(extradata ~= nil, err);
				end
				engine:delete(delete_sql, host, username or "", self.store, "");
				extradata[key] = data;
				local t, value = assert(serialize(extradata));
				engine:insert(insert_sql, host, username or "", self.store, "", t, value);
			end
		end
		return true;
	end);
	if not ok then return nil, result; end
	return result;
end

function map_store:get_all(key)
	if type(key) ~= "string" or key == "" then
		return nil, "get_all only supports non-empty string keys";
	end
	local ok, result = engine:transaction(function()
		local query = [[
		SELECT "user", "type", "value"
		FROM "prosody"
		WHERE "host"=? AND "store"=? AND "key"=?
		]];

		local data;
		for row in engine:select(query, host, self.store, key) do
			local key_data, err = deserialize(row[2], row[3]);
			assert(key_data ~= nil, err);
			if data == nil then
				data = {};
			end
			data[row[1]] = key_data;
		end

		return data;

	end);
	if not ok then return nil, result; end
	return result;
end

function map_store:delete_all(key)
	if type(key) ~= "string" or key == "" then
		return nil, "delete_all only supports non-empty string keys";
	end
	local ok, result = engine:transaction(function()
		local delete_sql = [[
		DELETE FROM "prosody"
		WHERE "host"=? AND "store"=? AND "key"=?;
		]];
		engine:delete(delete_sql, host, self.store, key);
		return true;
	end);
	if not ok then return nil, result; end
	return result;
end

local archive_store = {}
archive_store.caps = {
	total = true;
	quota = archive_item_limit;
	truncate = true;
	full_id_range = true;
	ids = true;
	wildcard_delete = true;
};
archive_store.__index = archive_store
function archive_store:append(username, key, value, when, with)
	local user,store = username,self.store;
	local cache_key = jid_join(username, host, store);
	local item_count = archive_item_count_cache:get(cache_key);

	if archive_item_limit then
		if not item_count then
			item_count_cache_miss();
			local ok, ret = engine:transaction(function()
				local count_sql = [[
				SELECT COUNT(*) FROM "prosodyarchive"
				WHERE "host"=? AND "user"=? AND "store"=?;
				]];
				local result = engine:select(count_sql, host, user, store);
				if result then
					for row in result do
						item_count = row[1];
					end
				end
			end);
			if not ok or not item_count then
				module:log("error", "Failed while checking quota for %s: %s", username, ret);
				return nil, "Failure while checking quota";
			end
			archive_item_count_cache:set(cache_key, item_count);
		else
			item_count_cache_hit();
		end

		module:log("debug", "%s has %d items out of %d limit", username, item_count, archive_item_limit);
		if item_count >= archive_item_limit then
			return nil, "quota-limit";
		end
	end

	-- FIXME update the schema to allow precision timestamps
	when = when or os.time();
	if engine.params.driver ~= "SQLite3" then
		-- SQLite3 doesn't enforce types :)
		when = math.floor(when);
	end
	with = with or "";
	local ok, ret = engine:transaction(function()
		local delete_sql = [[
		DELETE FROM "prosodyarchive"
		WHERE "host"=? AND "user"=? AND "store"=? AND "key"=?;
		]];
		local insert_sql = [[
		INSERT INTO "prosodyarchive"
		("host", "user", "store", "when", "with", "key", "type", "value")
		VALUES (?,?,?,?,?,?,?,?);
		]];
		if key then
			-- TODO use UPSERT like map store
			local result = engine:delete(delete_sql, host, user or "", store, key);
			if result and item_count then
				item_count = item_count - result:affected();
			end
		else
			key = uuid.v7();
		end
		local t, encoded_value = assert(serialize(value));
		engine:insert(insert_sql, host, user or "", store, when, with, key, t, encoded_value);
		if item_count then
			archive_item_count_cache:set(cache_key, item_count+1);
		end
		return key;
	end);
	if not ok then return ok, ret; end
	return ret; -- the key
end

-- Helpers for building the WHERE clause
local function archive_where(query, args, where)
	-- Time range, inclusive
	if query.start then
		args[#args+1] = math.floor(query.start);
		where[#where+1] = "\"when\" >= ?"
	end

	if query["end"] then
		args[#args+1] = math.floor(query["end"]);
		if query.start then
			where[#where] = "\"when\" BETWEEN ? AND ?" -- is this inclusive?
		else
			where[#where+1] = "\"when\" <= ?"
		end
	end

	-- Related name
	if query.with then
		where[#where+1] = "\"with\" = ?";
		args[#args+1] = query.with
	end

	-- Unique id
	if query.key then
		where[#where+1] = "\"key\" = ?";
		args[#args+1] = query.key
	end

	-- Set of ids
	if query.ids then
		local nids, nargs = #query.ids, #args;
		where[#where + 1] = "\"key\" IN (" .. string.rep("?", nids, ",") .. ")";
		for i, id in ipairs(query.ids) do
			args[nargs+i] = id;
		end
	end
end
local function archive_where_id_range(query, args, where)
	-- Before or after specific item, exclusive
	local id_lookup_sql = [[
	SELECT "sort_id"
	FROM "prosodyarchive"
	WHERE "key" = ? AND "host" = ? AND "user" = ? AND "store" = ?
	LIMIT 1;
	]];
	if query.after then  -- keys better be unique!
		local after_id = nil;
		for row in engine:select(id_lookup_sql, query.after, args[1], args[2], args[3]) do
			after_id = row[1];
		end
		if not after_id then
			return nil, "item-not-found";
		end
		where[#where+1] = '"sort_id" > ?';
		args[#args+1] = after_id;
	end
	if query.before then
		local before_id = nil;
		for row in engine:select(id_lookup_sql, query.before, args[1], args[2], args[3]) do
			before_id = row[1];
		end
		if not before_id then
			return nil, "item-not-found";
		end
		where[#where+1] = '"sort_id" < ?';
		args[#args+1] = before_id;
	end
	return true;
end

function archive_store:find(username, query)
	query = query or {};
	local user,store = username,self.store;
	local cache_key = jid_join(username, host, self.store);
	local total = archive_item_count_cache:get(cache_key);
	(total and item_count_cache_hit or item_count_cache_miss)();
	if query.start == nil and query.with == nil and query["end"] == nil and query.key == nil and query.ids == nil then
		-- the query is for the whole archive, so a cached 'total' should be a
		-- relatively accurate response if that's all that is requested
		if total ~= nil and query.limit == 0 then return noop, total; end
	else
		-- not usable, so refresh it later if needed
		total = nil;
	end
	local ok, result, err = engine:transaction(function()
		local sql_query = [[
		SELECT "key", "type", "value", "when", "with"
		FROM "prosodyarchive"
		WHERE %s
		ORDER BY "sort_id" %s%s;
		]];
		local args = { host, user or "", store, };
		local where = { "\"host\" = ?", "\"user\" = ?", "\"store\" = ?", };

		archive_where(query, args, where);

		-- Total matching
		if query.total and not total then

			local stats = engine:select("SELECT COUNT(*) FROM \"prosodyarchive\" WHERE "
				.. t_concat(where, " AND "), unpack(args));
			if stats then
				for row in stats do
					total = row[1];
				end
			end
			if query.start == nil and query.with == nil and query["end"] == nil and query.key == nil and query.ids == nil then
				archive_item_count_cache:set(cache_key, total);
			end
			if query.limit == 0 then -- Skip the real query
				return noop, total;
			end
		end

		local ok, err = archive_where_id_range(query, args, where);
		if not ok then return ok, err; end

		sql_query = sql_query:format(t_concat(where, " AND "), query.reverse
			and "DESC" or "ASC", query.limit and " LIMIT " .. query.limit or "");
		return engine:select(sql_query, unpack(args));
	end);
	if not ok then return ok, result; end
	if not result then return nil, err; end
	return function()
		local row = result();
		if row ~= nil then
			local value, err = deserialize(row[2], row[3]);
			assert(value ~= nil, err);
			return row[1], value, row[4], row[5];
		end
	end, total;
end

function archive_store:get(username, key)
	local iter, err = self:find(username, { key = key })
	if not iter then return iter, err; end
	for _, stanza, when, with in iter do
		return stanza, when, with;
	end
	return nil, "item-not-found";
end

function archive_store:set(username, key, new_value, new_when, new_with)
	local user,store = username,self.store;
	local ok, result = engine:transaction(function ()

		local update_query = [[
		UPDATE "prosodyarchive"
		SET %s
		WHERE %s
		]];
		local args = { host, user or "", store, key };
		local setf = {};
		local where = { "\"host\" = ?", "\"user\" = ?", "\"store\" = ?", "\"key\" = ?"};

		if new_value then
			table.insert(setf, '"type" = ?')
			table.insert(setf, '"value" = ?')
			local t, value = serialize(new_value);
			table.insert(args, 1, t);
			table.insert(args, 2, value);
		end

		if new_when then
			table.insert(setf, 1, '"when" = ?')
			table.insert(args, 1, new_when);
		end

		if new_with then
			table.insert(setf, 1, '"with" = ?')
			table.insert(args, 1, new_with);
		end

		update_query = update_query:format(t_concat(setf, ", "), t_concat(where, " AND "));
		return engine:update(update_query, unpack(args));
	end);
	if not ok then return ok, result; end
	return result:affected() == 1;
end

function archive_store:summary(username, query)
	query = query or {};
	local user,store = username,self.store;
	local ok, result = engine:transaction(function()
		local sql_query = [[
		SELECT DISTINCT "with", COUNT(*), MIN("when"), MAX("when")
		FROM "prosodyarchive"
		WHERE %s
		GROUP BY "with";
		]];
		local args = { host, user or "", store, };
		local where = { "\"host\" = ?", "\"user\" = ?", "\"store\" = ?", };

		archive_where(query, args, where);

		archive_where_id_range(query, args, where);

		if query.limit then
			args[#args+1] = query.limit;
		end

		sql_query = sql_query:format(t_concat(where, " AND "));
		return engine:select(sql_query, unpack(args));
	end);
	if not ok then return ok, result end
	local counts = {};
	local earliest, latest = {}, {};
	for row in result do
		local with, count = row[1], row[2];
		counts[with] = count;
		earliest[with] = row[3];
		latest[with] = row[4];
	end
	return {
		counts = counts;
		earliest = earliest;
		latest = latest;
	};
end

function archive_store:delete(username, query)
	query = query or {};
	local user,store = username,self.store;
	local ok, stmt = engine:transaction(function()
		local sql_query = "DELETE FROM \"prosodyarchive\" WHERE %s;";
		local args = { host, user or "", store, };
		local where = { "\"host\" = ?", "\"user\" = ?", "\"store\" = ?", };
		if user == true then
			table.remove(args, 2);
			table.remove(where, 2);
		end
		archive_where(query, args, where);
		local ok, err = archive_where_id_range(query, args, where);
		if not ok then return ok, err; end
		if query.truncate == nil then
			sql_query = sql_query:format(t_concat(where, " AND "));
		elseif engine.params.driver == "MySQL" then
			sql_query = [[
			DELETE result FROM prosodyarchive AS result JOIN (
				SELECT sort_id FROM prosodyarchive
				WHERE %s
				ORDER BY "sort_id" %s
				LIMIT 18446744073709551615 OFFSET %s
			) AS limiter on result.sort_id = limiter.sort_id;]];

			sql_query = string.format(sql_query, t_concat(where, " AND "),
				query.reverse and "ASC" or "DESC", query.truncate);
		else
			args[#args+1] = query.truncate;
			local unlimited = "ALL";
			sql_query = [[
			DELETE FROM "prosodyarchive"
			WHERE "sort_id" IN (
				SELECT "sort_id" FROM "prosodyarchive"
				WHERE %s
				ORDER BY "sort_id" %s
				LIMIT %s OFFSET ?
			);]];
			if engine.params.driver == "SQLite3" then
				if engine.sqlite_compile_options.enable_update_delete_limit then
					sql_query = [[
					DELETE FROM "prosodyarchive"
					WHERE %s
					ORDER BY "sort_id" %s
					LIMIT %s OFFSET ?;
					]];
				end
				unlimited = "-1";
			end
			sql_query = string.format(sql_query, t_concat(where, " AND "),
				query.reverse and "ASC" or "DESC", unlimited);
		end
		return engine:delete(sql_query, unpack(args));
	end);
	if username == true then
		archive_item_count_cache:clear();
	else
		local cache_key = jid_join(username, host, self.store);
		if query.start == nil and query.with == nil and query["end"] == nil and query.key == nil and query.ids == nil and query.truncate == nil then
			-- All items deleted, count should be zero.
			archive_item_count_cache:set(cache_key, 0);
		else
			-- Not sure how many items left
			archive_item_count_cache:set(cache_key, nil);
		end
	end
	return ok and stmt:affected(), stmt;
end

function archive_store:users()
	local ok, result = engine:transaction(function()
		local select_sql = [[
		SELECT DISTINCT "user"
		FROM "prosodyarchive"
		WHERE "host"=? AND "store"=?;
		]];
		return engine:select(select_sql, host, self.store);
	end);
	if not ok then error(result); end
	return iterator(result);
end

local keyvalplus = {
	__index = {
		-- keyval
		get = keyval_store.get;
		set = keyval_store.set;
		items = keyval_store.users;
		-- map
		get_key = map_store.get;
		set_key = map_store.set;
		remove = map_store.remove;
		set_keys = map_store.set_keys;
		get_key_from_all = map_store.get_all;
		delete_key_from_all = map_store.delete_all;
	};
}

local stores = {
	keyval = keyval_store;
	map = map_store;
	archive = archive_store;
	["keyval+"] = keyvalplus;
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
	local query = "SELECT DISTINCT \"store\" FROM \"prosody\" WHERE \"host\"=? AND \"user\"" ..
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
		engine:delete("DELETE FROM \"prosody\" WHERE \"host\"=? AND \"user\"=?", host, username);
		engine:delete("DELETE FROM \"prosodyarchive\" WHERE \"host\"=? AND \"user\"=?", host, username);
	end);
end

--- Initialization


local function create_table(engine) -- luacheck: ignore 431/engine
	local sql = get_sql_lib(engine.params.driver);
	local Table, Column, Index = sql.Table, sql.Column, sql.Index;

	local ProsodyTable = Table {
		name = "prosody";
		Column { name="host", type="TEXT", nullable=false };
		Column { name="user", type="TEXT", nullable=false };
		Column { name="store", type="TEXT", nullable=false };
		Column { name="key", type="TEXT", nullable=false };
		Column { name="type", type="TEXT", nullable=false };
		Column { name="value", type="MEDIUMTEXT", nullable=false };
		Index { name = "prosody_unique_index"; unique = engine.params.driver ~= "MySQL"; "host"; "user"; "store"; "key" };
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
		Index { name="prosodyarchive_index", unique = engine.params.driver ~= "MySQL", "host", "user", "store", "key" };
		Index { name="prosodyarchive_with_when", "host", "user", "store", "with", "when" };
		Index { name="prosodyarchive_when", "host", "user", "store", "when" };
		Index { name="prosodyarchive_sort", "host", "user", "store", "sort_id" };
	};
	engine:transaction(function()
		ProsodyArchiveTable:create(engine);
	end);
end

local function upgrade_table(engine, params, apply_changes) -- luacheck: ignore 431/engine
	local changes = false;
	if params.driver == "MySQL" then
		local sql = get_sql_lib("MySQL");
		local success,err = engine:transaction(function()
			do
				local result = assert(engine:execute("SHOW COLUMNS FROM \"prosody\" WHERE \"Field\"='value' and \"Type\"='text'"));
				if result:rowcount() > 0 then
					changes = true;
					if apply_changes then
						module:log("info", "Upgrading database schema (value column size)...");
						assert(engine:execute("ALTER TABLE \"prosody\" MODIFY COLUMN \"value\" MEDIUMTEXT"));
						module:log("info", "Database table automatically upgraded");
					end
				end
			end

			do
				-- Ensure index is not unique (issue #1073)
				local result = assert(engine:execute([[SHOW INDEX FROM prosodyarchive WHERE key_name='prosodyarchive_index' and non_unique=0]]));
				if result:rowcount() > 0 then
					changes = true;
					if apply_changes then
						module:log("info", "Upgrading database schema (prosodyarchive_index)...");
						assert(engine:execute[[ALTER TABLE "prosodyarchive" DROP INDEX prosodyarchive_index;]]);
						local new_index = sql.Index { table = "prosodyarchive", name="prosodyarchive_index", "host", "user", "store", "key" };
						assert(engine:_create_index(new_index));
						module:log("info", "Database table automatically upgraded");
					end
				end
			end
			return true;
		end);
		if not success then
			module:log("error", "Failed to check/upgrade database schema (%s), please see "
				.."https://prosody.im/doc/mysql for help",
				err or "unknown error");
			return false;
		end

		-- COMPAT w/pre-0.10: Upgrade table to UTF-8 if not already
		local check_encoding_query = [[
		SELECT "COLUMN_NAME","COLUMN_TYPE","TABLE_NAME"
		FROM "information_schema"."columns"
		WHERE "TABLE_NAME" LIKE 'prosody%%'
		AND "TABLE_SCHEMA" = ?
		AND ( "CHARACTER_SET_NAME"!=? OR "COLLATION_NAME"!=?);
		]];
		-- FIXME Is it ok to ignore the return values from this?
		engine:transaction(function()
			local result = assert(engine:execute(check_encoding_query, params.database, engine.charset, engine.charset.."_bin"));
			local n_bad_columns = result:rowcount();
			if n_bad_columns > 0 then
				changes = true;
				if apply_changes then
					module:log("warn", "Found %d columns in prosody table requiring encoding change, updating now...", n_bad_columns);
					local fix_column_query1 = "ALTER TABLE \"%s\" CHANGE \"%s\" \"%s\" BLOB;";
					local fix_column_query2 = "ALTER TABLE \"%s\" CHANGE \"%s\" \"%s\" %s CHARACTER SET '%s' COLLATE '%s_bin';";
					for row in result:rows() do
						local column_name, column_type, table_name  = unpack(row);
						module:log("debug", "Fixing column %s in table %s", column_name, table_name);
						engine:execute(fix_column_query1:format(table_name, column_name, column_name));
						engine:execute(fix_column_query2:format(table_name, column_name, column_name, column_type, engine.charset, engine.charset));
					end
					module:log("info", "Database encoding upgrade complete!");
				end
			end
		end);
		success,err = engine:transaction(function()
			return engine:execute(check_encoding_query, params.database,
				engine.charset, engine.charset.."_bin");
		end);
		if not success then
			module:log("error", "Failed to check/upgrade database encoding: %s", err or "unknown error");
			return false;
		end
	else
		local indices = {};
		engine:transaction(function ()
			if params.driver == "SQLite3" then
				for row in engine:select [[SELECT "name" FROM "sqlite_schema" WHERE "type"='index' AND "tbl_name"='prosody';]] do
					indices[row[1]] = true;
				end
			elseif params.driver == "PostgreSQL" then
				for row in engine:select [[SELECT "indexname" FROM "pg_indexes" WHERE "tablename"='prosody';]] do
					indices[row[1]] = true;
				end
			end
		end)
		if indices["prosody_index"] then
			local success = engine:transaction(function ()
				return assert(engine:execute([[DROP INDEX "prosody_index";]]));
			end);
			if not success then
				module:log("error", "Failed to delete obsolete index \"prosody_index\"");
				return false;
			end
		end
		if not indices["prosody_unique_index"] then
			module:log("warn", "Index \"prosody_unique_index\" does not exist, performance may be worse than normal!");
			engine.has_upsert_index = false;
		else
			engine.has_upsert_index = true;
		end
	end
	return changes;
end

local function normalize_database(driver, database) -- luacheck: ignore 431/driver
	if driver == "SQLite3" and database ~= ":memory:" then
		return resolve_relative_path(prosody.paths.data or ".", database or "prosody.sqlite");
	end
	return database;
end

local function normalize_params(params)
	return {
		driver = assert(params.driver,
			"Configuration error: Both the SQL driver and the database need to be specified");
		database = assert(normalize_database(params.driver, params.database),
			"Configuration error: Both the SQL driver and the database need to be specified");
		username = params.username;
		password = params.password;
		host = params.host;
		port = params.port;
	};
end

function module.load()
	local engines = module:shared("/*/sql/connections");
	local params = normalize_params(module:get_option("sql", default_params));
	local sql = get_sql_lib(params.driver);
	local db_uri = sql.db2uri(params);
	engine = engines[db_uri];
	if not engine then
		module:log("debug", "Creating new engine %s", db_uri);
		engine = sql:create_engine(params, function (engine) -- luacheck: ignore 431/engine
			if module:get_option_boolean("sql_manage_tables", true) then
				-- Automatically create table, ignore failure (table probably already exists)
				-- FIXME: we should check in information_schema, etc.
				create_table(engine);
				-- Check whether the table needs upgrading
				if upgrade_table(engine, params, false) then
					module:log("error", "Old database format detected. Please run: prosodyctl mod_%s upgrade", module.name);
					return false, "database upgrade needed";
				end
			end
			if engine.params.driver == "SQLite3" then
				local compile_options = {}
				for row in engine:select("PRAGMA compile_options") do
					local option = row[1]:lower();
					local opt, val = option:match("^([^=]+)=(.*)$");
					compile_options[opt or option] = tonumber(val) or val or true;
				end
				-- COMPAT Need to check SQLite3 version because SQLCipher 3.x was based on SQLite3 prior to 3.24.0 when UPSERT was introduced
				for row in engine:select("SELECT sqlite_version()") do
					local version = {};
					for n in row[1]:gmatch("%d+") do
						table.insert(version, tonumber(n));
					end
					engine.sqlite_version = version;
				end
				engine.sqlite_compile_options = compile_options;

				local journal_mode = "delete";
				for row in engine:select[[PRAGMA journal_mode;]] do
					journal_mode = row[1];
				end

				-- Note: These things can't be changed with in a transaction. LuaDBI
				-- opens a transaction automatically for every statement(?), so this
				-- will not work there.
				local tune = module:get_option_enum("sqlite_tune", "default", "normal", "fast", "safe");
				if tune == "normal" then
					if journal_mode ~= "wal" then
						engine:execute("PRAGMA journal_mode=WAL;");
					end
					engine:execute("PRAGMA auto_vacuum=FULL;");
					engine:execute("PRAGMA synchronous=NORMAL;")
				elseif tune == "fast" then
					if journal_mode ~= "wal" then
						engine:execute("PRAGMA journal_mode=WAL;");
					end
					if compile_options.secure_delete then
						engine:execute("PRAGMA secure_delete=FAST;");
					end
					engine:execute("PRAGMA synchronous=OFF;")
					engine:execute("PRAGMA fullfsync=0;")
				elseif tune == "safe" then
					if journal_mode ~= "delete" then
						engine:execute("PRAGMA journal_mode=DELETE;");
					end
					engine:execute("PRAGMA synchronous=EXTRA;")
					engine:execute("PRAGMA fullfsync=1;")
				end

				for row in engine:select[[PRAGMA journal_mode;]] do
					journal_mode = row[1];
				end

				module:log("debug", "SQLite3 database %q operating with journal_mode=%s", engine.params.database, journal_mode);
			end
			module:set_status("info", "Connected to " .. engine.params.driver);
		end, function (engine) -- luacheck: ignore 431/engine
			module:set_status("error", "Disconnected from " .. engine.params.driver);
		end);
		engines[sql.db2uri(params)] = engine;
	else
		module:set_status("info", "Using existing engine");
	end

	module:provides("storage", driver);
end

function module.command(arg)
	local config = require "prosody.core.configmanager";
	local hi = require "prosody.util.human.io";
	local command = table.remove(arg, 1);
	if command == "upgrade" then
		-- We need to find every unique dburi in the config
		local uris = {};
		for host in pairs(prosody.hosts) do -- luacheck: ignore 431/host
			local params = normalize_params(config.get(host, "sql") or default_params);
			local sql = get_sql_lib(engine.params.driver);
			uris[sql.db2uri(params)] = params;
		end
		print("We will check and upgrade the following databases:\n");
		for _, params in pairs(uris) do
			print("", "["..params.driver.."] "..params.database..(params.host and " on "..params.host or ""));
		end
		print("");
		print("Ensure you have working backups of the above databases before continuing! ");
		if false == hi.show_yesno("Continue with the database upgrade? [yN]") then
			print("Ok, no upgrade. But you do have backups, don't you? ...don't you?? :-)");
			return;
		end
		-- Upgrade each one
		for _, params in pairs(uris) do
			print("Checking "..params.database.."...");
			local sql = get_sql_lib(params.driver);
			engine = sql:create_engine(params);
			upgrade_table(engine, params, true);
		end
		print("All done!");
	elseif command then
		print("Unknown command: "..command);
	else
		print("Available commands:");
		print("","upgrade - Perform database upgrade");
	end
end

module:add_item("shell-command", {
	section = "sql";
	section_desc = "SQL management commands";
	name = "create";
	desc = "Create the tables and indices used by Prosody (again)";
	args = { { name = "host"; type = "string" } };
	host_selector = "host";
	handler = function(shell, _host)
		local logger = require "prosody.util.logger";
		local writing = false;
		local sink = logger.add_simple_sink(function (source, _level, message)
			local print = shell.session.print;
			if writing or source ~= "sql" then return; end
			writing = true;
			print(message);
			writing = false;
		end);

		local debug_enabled = engine._debug;
		engine:debug(true);
		create_table(engine);
		engine:debug(debug_enabled);

		if not logger.remove_sink(sink) then
			module:log("warn", "Unable to remove log sink");
		end
	end;
})
