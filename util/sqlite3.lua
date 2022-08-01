
-- luacheck: ignore 113/unpack 211 212 411 213
local setmetatable, getmetatable = setmetatable, getmetatable;
local ipairs, unpack, select = ipairs, table.unpack or unpack, select;
local tonumber, tostring = tonumber, tostring;
local assert, xpcall, debug_traceback = assert, xpcall, debug.traceback;
local error = error
local type = type
local t_concat = table.concat;
local t_insert = table.insert;
local s_char = string.char;
local log = require "util.logger".init("sql");

local lsqlite3 = require "lsqlite3";
local build_url = require "socket.url".build;
local ROW, DONE = lsqlite3.ROW, lsqlite3.DONE;
local err2str = {
	[0] = "OK";
	"ERROR";
	"INTERNAL";
	"PERM";
	"ABORT";
	"BUSY";
	"LOCKED";
	"NOMEM";
	"READONLY";
	"INTERRUPT";
	"IOERR";
	"CORRUPT";
	"NOTFOUND";
	"FULL";
	"CANTOPEN";
	"PROTOCOL";
	"EMPTY";
	"SCHEMA";
	"TOOBIG";
	"CONSTRAINT";
	"MISMATCH";
	"MISUSE";
	"NOLFS";
	[24] = "FORMAT";
	[25] = "RANGE";
	[26] = "NOTADB";
	[100] = "ROW";
	[101] = "DONE";
};

local assert = function(cond, errno, err)
	return assert(cond, err or err2str[errno]);
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
local function Integer(n) return "Integer()" end
local function String(n) return "String()" end

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
	for i,col in ipairs(self.__table__) do
		s[#s+1] = tostring(col);
	end
	return 'Table{ '..t_concat(s, ", ")..' }'
end
table_mt.__index = {};
function table_mt.__index:create(engine)
	return engine:_create_table(self);
end
function table_mt:__call(...)
	-- TODO
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

local function urldecode(s) return s and (s:gsub("%%(%x%x)", function (c) return s_char(tonumber(c,16)); end)); end
local function parse_url(url)
	local scheme, secondpart, database = url:match("^([%w%+]+)://([^/]*)/?(.*)");
	assert(scheme, "Invalid URL format");
	local username, password, host, port;
	local authpart, hostpart = secondpart:match("([^@]+)@([^@+])");
	if not authpart then hostpart = secondpart; end
	if authpart then
		username, password = authpart:match("([^:]*):(.*)");
		username = username or authpart;
		password = password and urldecode(password);
	end
	if hostpart then
		host, port = hostpart:match("([^:]*):(.*)");
		host = host or hostpart;
		port = port and assert(tonumber(port), "Invalid URL format");
	end
	return {
		scheme = scheme:lower();
		username = username; password = password;
		host = host; port = port;
		database = #database > 0 and database or nil;
	};
end

local engine = {};
function engine:connect()
	if self.conn then return true; end

	local params = self.params;
	assert(params.driver == "SQLite3", "Only sqlite3 is supported");
	local dbh, err = lsqlite3.open(params.database);
	if not dbh then return nil, err2str[err]; end
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
function engine:onconnect()
	-- Override from create_engine()
end
function engine:execute(sql, ...)
	local success, err = self:connect();
	if not success then return success, err; end
	local prepared = self.prepared;

	local stmt = prepared[sql];
	if not stmt then
		local err;
		stmt, err = self.conn:prepare(sql);
		if not stmt then return stmt, err; end
		prepared[sql] = stmt;
	end

	local ret = stmt:bind_values(...);
	if ret ~= lsqlite3.OK then return nil, self.conn:errmsg(); end
	return stmt;
end

local result_mt = {
	__index = {
	affected = function(self) return self.__affected; end;
	rowcount = function(self) return self.__rowcount; end;
	},
};

local function iterator(table)
	local i=0;
	return function()
		i=i+1;
		local item=table[i];
		if item ~= nil then
			return item;
		end
	end
end

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
	local prepared = self.prepared;
	local stmt = prepared[sql];
	if stmt and stmt:isopen() then
		prepared[sql] = nil; -- Can't be used concurrently
	else
		stmt = assert(self.conn:prepare(sql));
	end
	local ret = stmt:bind_values(...);
	if ret ~= lsqlite3.OK then error(self.conn:errmsg()); end
	local data, ret = {}
	while stmt:step() == ROW do
		t_insert(data, stmt:get_values());
	end
	-- FIXME Error handling, BUSY, ERROR, MISUSE
	if stmt:reset() == lsqlite3.OK then
		prepared[sql] = stmt;
	end
	return setmetatable({ __data = data }, { __index = result_mt.__index, __call = iterator(data) });
end
function engine:execute_update(sql, ...)
	local prepared = self.prepared;
	local stmt = prepared[sql];
	if not stmt or not stmt:isopen() then
		stmt = assert(self.conn:prepare(sql));
	else
		prepared[sql] = nil;
	end
	local ret = stmt:bind_values(...);
	if ret ~= lsqlite3.OK then error(self.conn:errmsg()); end
	local rowcount = 0;
	repeat
		ret = stmt:step();
		if ret == lsqlite3.ROW then
			rowcount = rowcount + 1;
		end
	until ret ~= lsqlite3.ROW;
	local affected = self.conn:changes();
	if stmt:reset() == lsqlite3.OK then
		prepared[sql] = stmt;
	end
	return setmetatable({ __affected = affected, __rowcount = rowcount }, result_mt);
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
	for i,v in ipairs(table.__table__) do
		if is_index(v) then
			self:_create_index(v);
		end
	end
	return success;
end
function engine:set_encoding() -- to UTF-8
	return self:transaction(function()
			for encoding in self:select"PRAGMA encoding;" do
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

local function create_engine(_, params, onconnect)
	assert(params.driver == "SQLite3", "Only SQLite3 is supported without LuaDBI");
	return setmetatable({ url = db2uri(params), params = params, onconnect = onconnect }, engine_mt);
end

return {
	is_column = is_column;
	is_index = is_index;
	is_table = is_table;
	is_query = is_query;
	Integer = Integer;
	String = String;
	Column = Column;
	Table = Table;
	Index = Index;
	create_engine = create_engine;
	db2uri = db2uri;
};
