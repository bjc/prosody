
local setmetatable, getmetatable = setmetatable, getmetatable;
local ipairs = ipairs;
local tostring = tostring;
local type = type;
local assert, pcall, debug_traceback = assert, pcall, debug.traceback;
local xpcall = require "prosody.util.xpcall".xpcall;
local t_concat = table.concat;
local log = require "prosody.util.logger".init("sql");

local DBI = require "DBI";
-- This loads all available drivers while globals are unlocked
-- LuaDBI should be fixed to not set globals.
DBI.Drivers();
local build_url = require "socket.url".build;

local _ENV = nil;
-- luacheck: std none

local column_mt = {};
local table_mt = {};
local query_mt = {};
--local op_mt = {};
local index_mt = {};

local function is_column(x) return getmetatable(x)==column_mt; end
local function is_index(x) return getmetatable(x)==index_mt; end
local function is_table(x) return getmetatable(x)==table_mt; end
local function is_query(x) return getmetatable(x)==query_mt; end

local function Column(definition)
	return setmetatable(definition, column_mt);
end
local function Table(definition)
	local c = {}
	for i,col in ipairs(definition) do
		if is_column(col) then
			c[i], c[col.name] = col, col;
		elseif is_index(col) then
			col.table = definition.name;
		end
	end
	return setmetatable({ __table__ = definition, c = c, name = definition.name }, table_mt);
end
local function Index(definition)
	return setmetatable(definition, index_mt);
end

function table_mt:__tostring()
	local s = { 'name="'..self.__table__.name..'"' }
	for _, col in ipairs(self.__table__) do
		s[#s+1] = tostring(col);
	end
	return 'Table{ '..t_concat(s, ", ")..' }'
end
table_mt.__index = {};
function table_mt.__index:create(engine)
	return engine:_create_table(self);
end
function column_mt:__tostring()
	return 'Column{ name="'..self.name..'", type="'..self.type..'" }'
end
function index_mt:__tostring()
	local s = 'Index{ name="'..self.name..'"';
	for i=1,#self do s = s..', "'..self[i]:gsub("[\\\"]", "\\%1")..'"'; end
	return s..' }';
--	return 'Index{ name="'..self.name..'", type="'..self.type..'" }'
end

local engine = {};
function engine:connect()
	if self.conn then return true; end

	local params = self.params;
	assert(params.driver, "no driver")
	log("debug", "Connecting to [%s] %s...", params.driver, params.database);
	local ok, dbh, err = pcall(DBI.Connect,
		params.driver, params.database,
		params.username, params.password,
		params.host, params.port
	);
	if not ok then return ok, dbh; end
	if not dbh then return nil, err; end
	dbh:autocommit(false); -- don't commit automatically
	self.conn = dbh;
	self.prepared = {};
	local ok, err = self:set_encoding();
	if not ok then
		return ok, err;
	end
	local ok, err = self:onconnect();
	if ok == false then
		return ok, err;
	end
	return true;
end
function engine:onconnect() -- luacheck: ignore 212/self
	-- Override from create_engine()
end
function engine:ondisconnect() -- luacheck: ignore 212/self
	-- Override from create_engine()
end

function engine:prepquery(sql)
	if self.params.driver == "MySQL" then
		sql = sql:gsub("\"", "`");
	end
	return sql;
end

function engine:execute(sql, ...)
	local success, err = self:connect();
	if not success then return success, err; end
	local prepared = self.prepared;

	sql = self:prepquery(sql);
	local stmt = prepared[sql];
	if not stmt then
		local err;
		stmt, err = self.conn:prepare(sql);
		if not stmt then return stmt, err; end
		prepared[sql] = stmt;
	end

	-- luacheck: ignore 411/success
	local success, err = stmt:execute(...);
	if not success then return success, err; end
	return stmt;
end

local result_mt = { __index = {
	affected = function(self) return self.__stmt:affected(); end;
	rowcount = function(self) return self.__stmt:rowcount(); end;
} };

local function debugquery(where, sql, ...)
	local i = 0; local a = {...}
	sql = sql:gsub("\n?\t+", " ");
	log("debug", "[%s] %s", where, (sql:gsub("%?", function ()
		i = i + 1;
		local v = a[i];
		if type(v) == "string" then
			v = ("'%s'"):format(v:gsub("'", "''"));
		end
		return tostring(v);
	end)));
end

function engine:execute_query(sql, ...)
	sql = self:prepquery(sql);
	local stmt = assert(self.conn:prepare(sql));
	assert(stmt:execute(...));
	local result = {};
	for row in stmt:rows() do result[#result + 1] = row; end
	stmt:close();
	local i = 0;
	return function() i=i+1; return result[i]; end;
end
function engine:execute_update(sql, ...)
	sql = self:prepquery(sql);
	local prepared = self.prepared;
	local stmt = prepared[sql];
	if not stmt then
		stmt = assert(self.conn:prepare(sql));
		prepared[sql] = stmt;
	end
	assert(stmt:execute(...));
	return setmetatable({ __stmt = stmt }, result_mt);
end
engine.insert = engine.execute_update;
engine.select = engine.execute_query;
engine.delete = engine.execute_update;
engine.update = engine.execute_update;
local function debugwrap(name, f)
	return function (self, sql, ...)
		debugquery(name, sql, ...)
		return f(self, sql, ...)
	end
end
function engine:debug(enable)
	self._debug = enable;
	if enable then
		engine.insert = debugwrap("insert", engine.execute_update);
		engine.select = debugwrap("select", engine.execute_query);
		engine.delete = debugwrap("delete", engine.execute_update);
		engine.update = debugwrap("update", engine.execute_update);
	else
		engine.insert = engine.execute_update;
		engine.select = engine.execute_query;
		engine.delete = engine.execute_update;
		engine.update = engine.execute_update;
	end
end
local function handleerr(err)
	local trace = debug_traceback(err, 3);
	log("debug", "Error in SQL transaction: %s", trace);
	return { err = err, traceback = trace };
end
function engine:_transaction(func, ...)
	if not self.conn then
		local ok, err = self:connect();
		if not ok then return ok, err; end
	end
	--assert(not self.__transaction, "Recursive transactions not allowed");
	log("debug", "SQL transaction begin [%s]", func);
	self.__transaction = true;
	local success, a, b, c = xpcall(func, handleerr, ...);
	self.__transaction = nil;
	if success then
		log("debug", "SQL transaction success [%s]", func);
		local ok, err = self.conn:commit();
		-- LuaDBI doesn't actually return an error message here, just a boolean
		if not ok then return ok, err or "commit failed"; end
		return success, a, b, c;
	else
		log("debug", "SQL transaction failure [%s]: %s", func, a.err);
		if self.conn then self.conn:rollback(); end
		return success, a.err;
	end
end
function engine:transaction(...)
	local ok, ret, b, c = self:_transaction(...);
	if not ok then
		local conn = self.conn;
		if not conn or not conn:ping() then
			log("debug", "Database connection was closed. Will reconnect and retry.");
			self.conn = nil;
			self:ondisconnect();
			log("debug", "Retrying SQL transaction [%s]", (...));
			ok, ret, b, c = self:_transaction(...);
			log("debug", "SQL transaction retry %s", ok and "succeeded" or "failed");
		else
			log("debug", "SQL connection is up, so not retrying");
		end
		if not ok then
			log("error", "Error in SQL transaction: %s", ret);
		end
	end
	return ok, ret, b, c;
end
function engine:_create_index(index)
	local sql = "CREATE INDEX \""..index.name.."\" ON \""..index.table.."\" (";
	if self.params.driver ~= "MySQL" then
		sql = sql:gsub("^CREATE INDEX", "%1 IF NOT EXISTS");
	end
	for i=1,#index do
		sql = sql.."\""..index[i].."\"";
		if i ~= #index then sql = sql..", "; end
	end
	sql = sql..");"
	if self.params.driver == "MySQL" then
		sql = sql:gsub("\"([,)])", "\"(20)%1");
	end
	if index.unique then
		sql = sql:gsub("^CREATE", "CREATE UNIQUE");
	end
	if self._debug then
		debugquery("create", sql);
	end
	return self:execute(sql);
end
function engine:_create_table(table)
	local sql = "CREATE TABLE \""..table.name.."\" (";
	do
		sql = sql:gsub("^CREATE TABLE", "%1 IF NOT EXISTS");
	end
	for i,col in ipairs(table.c) do
		local col_type = col.type;
		if col_type == "MEDIUMTEXT" and self.params.driver ~= "MySQL" then
			col_type = "TEXT"; -- MEDIUMTEXT is MySQL-specific
		end
		if col.auto_increment == true and self.params.driver == "PostgreSQL" then
			col_type = "BIGSERIAL";
		end
		sql = sql.."\""..col.name.."\" "..col_type;
		if col.nullable == false then sql = sql.." NOT NULL"; end
		if col.primary_key == true then sql = sql.." PRIMARY KEY"; end
		if col.auto_increment == true then
			if self.params.driver == "MySQL" then
				sql = sql.." AUTO_INCREMENT";
			elseif self.params.driver == "SQLite3" then
				sql = sql.." AUTOINCREMENT";
			end
		end
		if i ~= #table.c then sql = sql..", "; end
	end
	sql = sql.. ");"
	if self.params.driver == "MySQL" then
		sql = sql:gsub(";$", (" CHARACTER SET '%s' COLLATE '%s_bin';"):format(self.charset, self.charset));
	end
	if self._debug then
		debugquery("create", sql);
	end
	local success,err = self:execute(sql);
	if not success then return success,err; end
	for _, v in ipairs(table.__table__) do
		if is_index(v) then
			self:_create_index(v);
		end
	end
	return success;
end
function engine:set_encoding() -- to UTF-8
	local driver = self.params.driver;
	if driver == "SQLite3" then
		return self:transaction(function()
			for encoding in self:select"PRAGMA encoding;" do
				if encoding[1] == "UTF-8" then
					self.charset = "utf8";
				end
			end
		end);
	end
	local set_names_query = "SET NAMES '%s';"
	local charset = "utf8";
	if driver == "MySQL" then
		self:transaction(function()
			for row in self:select[[
				SELECT "CHARACTER_SET_NAME"
				FROM "information_schema"."CHARACTER_SETS"
				WHERE "CHARACTER_SET_NAME" LIKE 'utf8%'
				ORDER BY MAXLEN DESC LIMIT 1;
				]] do
				charset = row and row[1] or charset;
			end
		end);
		set_names_query = set_names_query:gsub(";$", (" COLLATE '%s';"):format(charset.."_bin"));
	end
	self.charset = charset;
	log("debug", "Using encoding '%s' for database connection", charset);
	local ok, err = self:transaction(function() return self:execute(set_names_query:format(charset)); end);
	if not ok then
		return ok, err;
	end

	if driver == "MySQL" then
		local ok, actual_charset = self:transaction(function ()
			return self:select"SHOW SESSION VARIABLES LIKE 'character_set_client'";
		end);
		if not ok then
			return false, "Failed to detect connection encoding";
		end
		local charset_ok = true;
		for row in actual_charset do
			if row[2] ~= charset then
				log("error", "MySQL %s is actually %q (expected %q)", row[1], row[2], charset);
				charset_ok = false;
			end
		end
		if not charset_ok then
			return false, "Failed to set connection encoding";
		end
	end

	return true;
end
local engine_mt = { __index = engine };

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

local function create_engine(_, params, onconnect, ondisconnect)
	return setmetatable({ url = db2uri(params); params = params; onconnect = onconnect; ondisconnect = ondisconnect }, engine_mt);
end

return {
	is_column = is_column;
	is_index = is_index;
	is_table = is_table;
	is_query = is_query;
	Column = Column;
	Table = Table;
	Index = Index;
	create_engine = create_engine;
	db2uri = db2uri;
};
