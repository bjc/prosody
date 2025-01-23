
local setmetatable, getmetatable = setmetatable, getmetatable;
local ipairs, select = ipairs, select;
local tostring = tostring;
local assert, xpcall, debug_traceback = assert, xpcall, debug.traceback;
local error = error
local type = type
local t_concat = table.concat;
local array = require "prosody.util.array";
local log = require "prosody.util.logger".init("sql");

local lsqlite3 = require "lsqlite3";
local build_url = require "socket.url".build;

-- from sqlite3.h, no copyright claimed
local sqlite_errors = require"prosody.util.error".init("util.sqlite3", {
	-- FIXME xmpp error conditions?
	[1] = { code = 1;     type = "modify";   condition = "ERROR";      text = "Generic error" };
	[2] = { code = 2;     type = "cancel";   condition = "INTERNAL";   text = "Internal logic error in SQLite" };
	[3] = { code = 3;     type = "auth";     condition = "PERM";       text = "Access permission denied" };
	[4] = { code = 4;     type = "cancel";   condition = "ABORT";      text = "Callback routine requested an abort" };
	[5] = { code = 5;     type = "wait";     condition = "BUSY";       text = "The database file is locked" };
	[6] = { code = 6;     type = "wait";     condition = "LOCKED";     text = "A table in the database is locked" };
	[7] = { code = 7;     type = "wait";     condition = "NOMEM";      text = "A malloc() failed" };
	[8] = { code = 8;     type = "cancel";   condition = "READONLY";   text = "Attempt to write a readonly database" };
	[9] = { code = 9;     type = "cancel";   condition = "INTERRUPT";  text = "Operation terminated by sqlite3_interrupt()" };
	[10] = { code = 10;   type = "wait";     condition = "IOERR";      text = "Some kind of disk I/O error occurred" };
	[11] = { code = 11;   type = "cancel";   condition = "CORRUPT";    text = "The database disk image is malformed" };
	[12] = { code = 12;   type = "modify";   condition = "NOTFOUND";   text = "Unknown opcode in sqlite3_file_control()" };
	[13] = { code = 13;   type = "wait";     condition = "FULL";       text = "Insertion failed because database is full" };
	[14] = { code = 14;   type = "auth";     condition = "CANTOPEN";   text = "Unable to open the database file" };
	[15] = { code = 15;   type = "cancel";   condition = "PROTOCOL";   text = "Database lock protocol error" };
	[16] = { code = 16;   type = "continue"; condition = "EMPTY";      text = "Internal use only" };
	[17] = { code = 17;   type = "modify";   condition = "SCHEMA";     text = "The database schema changed" };
	[18] = { code = 18;   type = "modify";   condition = "TOOBIG";     text = "String or BLOB exceeds size limit" };
	[19] = { code = 19;   type = "modify";   condition = "CONSTRAINT"; text = "Abort due to constraint violation" };
	[20] = { code = 20;   type = "modify";   condition = "MISMATCH";   text = "Data type mismatch" };
	[21] = { code = 21;   type = "modify";   condition = "MISUSE";     text = "Library used incorrectly" };
	[22] = { code = 22;   type = "cancel";   condition = "NOLFS";      text = "Uses OS features not supported on host" };
	[23] = { code = 23;   type = "auth";     condition = "AUTH";       text = "Authorization denied" };
	[24] = { code = 24;   type = "modify";   condition = "FORMAT";     text = "Not used" };
	[25] = { code = 25;   type = "modify";   condition = "RANGE";      text = "2nd parameter to sqlite3_bind out of range" };
	[26] = { code = 26;   type = "cancel";   condition = "NOTADB";     text = "File opened that is not a database file" };
	[27] = { code = 27;   type = "continue"; condition = "NOTICE";     text = "Notifications from sqlite3_log()" };
	[28] = { code = 28;   type = "continue"; condition = "WARNING";    text = "Warnings from sqlite3_log()" };
	[100] = { code = 100; type = "continue"; condition = "ROW";        text = "sqlite3_step() has another row ready" };
	[101] = { code = 101; type = "continue"; condition = "DONE";       text = "sqlite3_step() has finished executing" };
});

-- luacheck: ignore 411/assert
local assert = function(cond, errno, err)
	return assert(sqlite_errors.coerce(cond, err or errno));
end
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
	assert(params.driver == "SQLite3", "Only sqlite3 is supported");
	local dbh, err = sqlite_errors.coerce(lsqlite3.open(params.database));
	if not dbh then return nil, err; end
	self.conn = dbh;
	self.prepared = {};
	if params.password then
		local ok, err = self:execute(("PRAGMA key='%s'"):format((params.password:gsub("'", "''"))));
		if not ok then
			return ok, err;
		end
	end
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

function engine:execute(sql, ...)
	local success, err = self:connect();
	if not success then return success, err; end

	if select('#', ...) == 0 then
		local ret = self.conn:exec(sql);
		if ret ~= lsqlite3.OK then
			local err = sqlite_errors.new(err);
			err.text = self.conn:errmsg();
			return err;
		end
		return true;
	end

	local stmt, err = self.conn:prepare(sql);
	if not stmt then
		err = sqlite_errors.new(err);
		err.text = self.conn:errmsg();
		return stmt, err;
	end

	local ret = stmt:bind_values(...);
	if ret ~= lsqlite3.OK then
		return nil, sqlite_errors.new(ret, { message = self.conn:errmsg() });
	end
	return stmt;
end

local function iterator(table)
	local i = 0;
	return function()
		i = i + 1;
		local item = table[i];
		if item ~= nil then
			return item;
		end
	end
end

local result_mt = {
	__len = function(self)
		return self.__rowcount;
	end;
	__index = {
		affected = function(self)
			return self.__affected;
		end;
		rowcount = function(self)
			return self.__rowcount;
		end;
	};
	__call = function(self)
		return iterator(self.__data);
	end;
};

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

function engine:execute_update(sql, ...)
	local prepared = self.prepared;
	local stmt = prepared[sql];
	if stmt and stmt:isopen() then
		prepared[sql] = nil; -- Can't be used concurrently
	else
		stmt = assert(self.conn:prepare(sql));
	end
	local ret = stmt:bind_values(...);
	if ret ~= lsqlite3.OK then error(self.conn:errmsg()); end
	local data = array();
	for row in stmt:rows() do
		data:push(array(row));
	end
	-- FIXME Error handling, BUSY, ERROR, MISUSE
	if stmt:reset() == lsqlite3.OK then
		prepared[sql] = stmt;
	end
	local affected = self.conn:changes();
	return setmetatable({ __affected = affected; __rowcount = #data; __data = data }, result_mt);
end

function engine:execute_query(sql, ...)
	return self:execute_update(sql, ...)()
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
function engine:_(word)
	local ret = self.conn:exec(word);
	if ret ~= lsqlite3.OK then return nil, self.conn:errmsg(); end
	return true;
end
function engine:_transaction(func, ...)
	if not self.conn then
		local a,b = self:connect();
		if not a then return a,b; end
	end
	--assert(not self.__transaction, "Recursive transactions not allowed");
	local ok, err = self:_"BEGIN";
	if not ok then return ok, err; end
	self.__transaction = true;
	local success, a, b, c = xpcall(func, debug_traceback, ...);
	self.__transaction = nil;
	if success then
		log("debug", "SQL transaction success [%s]", tostring(func));
		local ok, err = self:_"COMMIT";
		if not ok then return ok, err; end -- commit failed
		return success, a, b, c;
	else
		log("debug", "SQL transaction failure [%s]: %s", tostring(func), a);
		if self.conn then self:_"ROLLBACK"; end
		return success, a;
	end
end
function engine:transaction(...)
	local ok, ret = self:_transaction(...);
	if not ok then
		local conn = self.conn;
		if not conn or not conn:isopen() then
			self.conn = nil;
			self:ondisconnect();
			ok, ret = self:_transaction(...);
		end
	end
	return ok, ret;
end
function engine:_create_index(index)
	local sql = "CREATE INDEX IF NOT EXISTS \""..index.name.."\" ON \""..index.table.."\" (";
	for i=1,#index do
		sql = sql.."\""..index[i].."\"";
		if i ~= #index then sql = sql..", "; end
	end
	sql = sql..");"
	if index.unique then
		sql = sql:gsub("^CREATE", "CREATE UNIQUE");
	end
	if self._debug then
		debugquery("create", sql);
	end
	return self:execute(sql);
end
function engine:_create_table(table)
	local sql = "CREATE TABLE IF NOT EXISTS \""..table.name.."\" (";
	for i,col in ipairs(table.c) do
		local col_type = col.type;
		sql = sql.."\""..col.name.."\" "..col_type;
		if col.nullable == false then sql = sql.." NOT NULL"; end
		if col.primary_key == true then sql = sql.." PRIMARY KEY"; end
		if col.auto_increment == true then
			sql = sql.." AUTOINCREMENT";
		end
		if i ~= #table.c then sql = sql..", "; end
	end
	sql = sql.. ");"
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
	return self:transaction(function()
		for encoding in self:select "PRAGMA encoding;" do
			if encoding[1] == "UTF-8" then
				self.charset = "utf8";
			end
		end
	end);
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
	assert(params.driver == "SQLite3", "Only SQLite3 is supported without LuaDBI");
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
