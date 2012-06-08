
-- Basic SQL driver
-- This driver stores data as simple key-values

local ser = require "util.serialization".serialize;
local envload = require "util.envload".envload;
local deser = function(data)
	module:log("debug", "deser: %s", tostring(data));
	if not data then return nil; end
	local f = envload("return "..data, nil, {});
	if not f then return nil; end
	local s, d = pcall(f);
	if not s then return nil; end
	return d;
end;

local driver = {};
driver.__index = driver;

driver.item_table = "item";
driver.list_table = "list";

function driver:prepare(sql)
	module:log("debug", "query: %s", sql);
	local err;
	if not self.sqlcache then self.sqlcache = {}; end
	local r = self.sqlcache[sql];
	if r then return r; end
	r, err = self.connection:prepare(sql);
	if not r then error("Unable to prepare SQL statement: "..err); end
	self.sqlcache[sql] = r;
	return r;
end

function driver:load(username, host, datastore)
	local select = self:prepare("select data from "..self.item_table.." where username=? and host=? and datastore=?");
	select:execute(username, host, datastore);
	local row = select:fetch();
	return row and deser(row[1]) or nil;
end

function driver:store(username, host, datastore, data)
	if not data or next(data) == nil then
		local delete = self:prepare("delete from "..self.item_table.." where username=? and host=? and datastore=?");
		delete:execute(username, host, datastore);
		return true;
	else
		local d = self:load(username, host, datastore);
		if d then -- update
			local update = self:prepare("update "..self.item_table.." set data=? where username=? and host=? and datastore=?");
			return update:execute(ser(data), username, host, datastore);
		else -- insert
			local insert = self:prepare("insert into "..self.item_table.." values (?, ?, ?, ?)");
			return insert:execute(username, host, datastore, ser(data));
		end
	end
end

function driver:list_append(username, host, datastore, data)
	if not data then return; end
	local insert = self:prepare("insert into "..self.list_table.." values (?, ?, ?, ?)");
	return insert:execute(username, host, datastore, ser(data));
end

function driver:list_store(username, host, datastore, data)
	-- remove existing data
	local delete = self:prepare("delete from "..self.list_table.." where username=? and host=? and datastore=?");
	delete:execute(username, host, datastore);
	if data and next(data) ~= nil then
		-- add data
		for _, d in ipairs(data) do
			self:list_append(username, host, datastore, ser(d));
		end
	end
	return true;
end

function driver:list_load(username, host, datastore)
	local select = self:prepare("select data from "..self.list_table.." where username=? and host=? and datastore=?");
	select:execute(username, host, datastore);
	local r = {};
	for row in select:rows() do
		table.insert(r, deser(row[1]));
	end
	return r;
end

local _M = {};
function _M.new(dbtype, dbname, ...)
	local d = {};
	setmetatable(d, driver);
	local dbh = get_database(dbtype, dbname, ...);
	--d:set_connection(dbh);
	d.connection = dbh;
	return d;
end
return _M;
