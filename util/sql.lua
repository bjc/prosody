
local setmetatable, getmetatable = setmetatable, getmetatable;
local ipairs, unpack, select = ipairs, unpack, select;
local tonumber, tostring = tonumber, tostring;
local assert, xpcall, debug_traceback = assert, xpcall, debug.traceback;
local t_concat = table.concat;
local s_char = string.char;
local log = require "util.logger".init("sql");

local DBI = require "DBI";
-- This loads all available drivers while globals are unlocked
-- LuaDBI should be fixed to not set globals.
DBI.Drivers();
local build_url = require "socket.url".build;

module("sql")

local column_mt = {};
local table_mt = {};
local query_mt = {};
--local op_mt = {};
local index_mt = {};

function is_column(x) return getmetatable(x)==column_mt; end
function is_index(x) return getmetatable(x)==index_mt; end
function is_table(x) return getmetatable(x)==table_mt; end
function is_query(x) return getmetatable(x)==query_mt; end
--function is_op(x) return getmetatable(x)==op_mt; end
--function expr(...) return setmetatable({...}, op_mt); end
function Integer(n) return "Integer()" end
function String(n) return "String()" end

--[[local ops = {
	__add = function(a, b) return "("..a.."+"..b..")" end;
	__sub = function(a, b) return "("..a.."-"..b..")" end;
	__mul = function(a, b) return "("..a.."*"..b..")" end;
	__div = function(a, b) return "("..a.."/"..b..")" end;
	__mod = function(a, b) return "("..a.."%"..b..")" end;
	__pow = function(a, b) return "POW("..a..","..b..")" end;
	__unm = function(a) return "NOT("..a..")" end;
	__len = function(a) return "COUNT("..a..")" end;
	__eq = function(a, b) return "("..a.."=="..b..")" end;
	__lt = function(a, b) return "("..a.."<"..b..")" end;
	__le = function(a, b) return "("..a.."<="..b..")" end;
};

local functions = {

};

local cmap = {
	[Integer] = Integer();
	[String] = String();
};]]

function Column(definition)
	return setmetatable(definition, column_mt);
end
function Table(definition)
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
function Index(definition)
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
--

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

--[[local session = {};

function session.query(...)
	local rets = {...};
	local query = setmetatable({ __rets = rets, __filters }, query_mt);
	return query;
end
--

local function db2uri(params)
	return build_url{
		scheme = params.driver,
		user = params.username,
		password = params.password,
		host = params.host,
		port = params.port,
		path = params.database,
	};
end]]

local engine = {};
function engine:connect()
	if self.conn then return true; end

	local params = self.params;
	assert(params.driver, "no driver")
	local dbh, err = DBI.Connect(
		params.driver, params.database,
		params.username, params.password,
		params.host, params.port
	);
	if not dbh then return nil, err; end
	dbh:autocommit(false); -- don't commit automatically
	self.conn = dbh;
	self.prepared = {};
	return true;
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

	local success, err = stmt:execute(...);
	if not success then return success, err; end
	return stmt;
end

local result_mt = { __index = {
	affected = function(self) return self.__stmt:affected(); end;
	rowcount = function(self) return self.__stmt:rowcount(); end;
} };

function engine:execute_query(sql, ...)
	if self.params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
	local stmt = assert(self.conn:prepare(sql));
	assert(stmt:execute(...));
	return stmt:rows();
end
function engine:execute_update(sql, ...)
	if self.params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
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
function engine:_transaction(func, ...)
	if not self.conn then
		local a,b = self:connect();
		if not a then return a,b; end
	end
	--assert(not self.__transaction, "Recursive transactions not allowed");
	local args, n_args = {...}, select("#", ...);
	local function f() return func(unpack(args, 1, n_args)); end
	self.__transaction = true;
	local success, a, b, c = xpcall(f, debug_traceback);
	self.__transaction = nil;
	if success then
		log("debug", "SQL transaction success [%s]", tostring(func));
		local ok, err = self.conn:commit();
		if not ok then return ok, err; end -- commit failed
		return success, a, b, c;
	else
		log("debug", "SQL transaction failure [%s]: %s", tostring(func), a);
		if self.conn then self.conn:rollback(); end
		return success, a;
	end
end
function engine:transaction(...)
	local a,b = self:_transaction(...);
	if not a then
		local conn = self.conn;
		if not conn or not conn:ping() then
			self.conn = nil;
			a,b = self:_transaction(...);
		end
	end
	return a,b;
end
function engine:_create_index(index)
	local sql = "CREATE INDEX `"..index.name.."` ON `"..index.table.."` (";
	for i=1,#index do
		sql = sql.."`"..index[i].."`";
		if i ~= #index then sql = sql..", "; end
	end
	sql = sql..");"
	if self.params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	elseif self.params.driver == "MySQL" then
		sql = sql:gsub("`([,)])", "`(20)%1");
	end
	if index.unique then
		sql = sql:gsub("^CREATE", "CREATE UNIQUE");
	end
	--print(sql);
	return self:execute(sql);
end
function engine:_create_table(table)
	local sql = "CREATE TABLE `"..table.name.."` (";
	for i,col in ipairs(table.c) do
		sql = sql.."`"..col.name.."` "..col.type;
		if col.nullable == false then sql = sql.." NOT NULL"; end
		if col.primary_key == true then sql = sql.." PRIMARY KEY"; end
		if col.auto_increment == true then
			if self.params.driver == "PostgreSQL" then
				sql = sql.." SERIAL";
			elseif self.params.driver == "MySQL" then
				sql = sql.." AUTO_INCREMENT";
			elseif self.params.driver == "SQLite3" then
				sql = sql.." AUTOINCREMENT";
			end
		end
		if i ~= #table.c then sql = sql..", "; end
	end
	sql = sql.. ");"
	if self.params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	elseif self.params.driver == "MySQL" then
		sql = sql:gsub(";$", " CHARACTER SET 'utf8' COLLATE 'utf8_bin';");
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
	local driver = self.params.driver;
	if driver == "SQLite3" then
		return self:transaction(function()
			if self:select"PRAGMA encoding;"()[1] == "UTF-8" then
				self.charset = "utf8";
			end
		end);
	end
	local set_names_query = "SET NAMES '%s';"
	local charset = "utf8";
	if driver == "MySQL" then
		set_names_query = set_names_query:gsub(";$", " COLLATE 'utf8_bin';");
		local ok, charsets = self:transaction(function()
			return self:select"SELECT `CHARACTER_SET_NAME` FROM `CHARACTER_SETS` WHERE `CHARACTER_SET_NAME` LIKE 'utf8%' ORDER BY MAXLEN DESC LIMIT 1;";
		end);
		local row = ok and charsets();
		charset = row and row[1] or charset;
	end
	self.charset = charset;
	return self:transaction(function() return engine:execute(set_names_query:format(charset)); end);
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
local engine_cache = {}; -- TODO make weak valued
function create_engine(self, params)
	local url = db2uri(params);
	if not engine_cache[url] then
		local engine = setmetatable({ url = url, params = params }, engine_mt);
		engine_cache[url] = engine;
	end
	return engine_cache[url];
end


--[[Users = Table {
	name="users";
	Column { name="user_id", type=String(), primary_key=true };
};
print(Users)
print(Users.c.user_id)]]

--local engine = create_engine('postgresql://scott:tiger@localhost:5432/mydatabase');
--[[local engine = create_engine{ driver = "SQLite3", database = "./alchemy.sqlite" };

local i = 0;
for row in assert(engine:execute("select * from sqlite_master")):rows(true) do
	i = i+1;
	print(i);
	for k,v in pairs(row) do
		print("",k,v);
	end
end
print("---")

Prosody = Table {
	name="prosody";
	Column { name="host", type="TEXT", nullable=false };
	Column { name="user", type="TEXT", nullable=false };
	Column { name="store", type="TEXT", nullable=false };
	Column { name="key", type="TEXT", nullable=false };
	Column { name="type", type="TEXT", nullable=false };
	Column { name="value", type="TEXT", nullable=false };
	Index { name="prosody_index", "host", "user", "store", "key" };
};
--print(Prosody);
assert(engine:transaction(function()
	assert(Prosody:create(engine));
end));

for row in assert(engine:execute("select user from prosody")):rows(true) do
	print("username:", row['username'])
end
--result.close();]]

return _M;
