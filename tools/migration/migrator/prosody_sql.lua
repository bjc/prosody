
local assert = assert;
local have_DBI = pcall(require,"DBI");
local print = print;
local type = type;
local next = next;
local pairs = pairs;
local t_sort = table.sort;
local json = require "util.json";
local mtools = require "migrator.mtools";
local tostring = tostring;
local tonumber = tonumber;

if not have_DBI then
	error("LuaDBI (required for SQL support) was not found, please see https://prosody.im/doc/depends#luadbi", 0);
end

local sql = require "util.sql";

local function create_table(engine, name) -- luacheck: ignore 431/engine
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

local function decode_user(item)
	local userdata = {
		user = item[1][1].user;
		host = item[1][1].host;
		stores = {};
	};
	for i=1,#item do -- loop over stores
		local result = {};
		local store = item[i];
		for i=1,#store do -- loop over store data
			local row = store[i];
			local k = row.key;
			local v = deserialize(row.type, row.value);
			if k and v then
				if k ~= "" then result[k] = v; elseif type(v) == "table" then
					for a,b in pairs(v) do
						result[a] = b;
					end
				end
			end
			userdata.stores[store[1].store] = result;
		end
	end
	return userdata;
end

local function needs_upgrade(engine, params)
	if params.driver == "MySQL" then
		local success = engine:transaction(function()
			local result = engine:execute("SHOW COLUMNS FROM prosody WHERE Field='value' and Type='text'");
			assert(result:rowcount() == 0);

			-- COMPAT w/pre-0.10: Upgrade table to UTF-8 if not already
			local check_encoding_query = [[
			SELECT `COLUMN_NAME`,`COLUMN_TYPE`,`TABLE_NAME`
			FROM `information_schema`.`columns`
			WHERE `TABLE_NAME` LIKE 'prosody%%' AND ( `CHARACTER_SET_NAME`!='%s' OR `COLLATION_NAME`!='%s_bin' );
			]];
			check_encoding_query = check_encoding_query:format(engine.charset, engine.charset);
			local result = engine:execute(check_encoding_query);
			assert(result:rowcount() == 0)
		end);
		if not success then
			-- Upgrade required
			return true;
		end
	end
	return false;
end

local function reader(input)
	local engine = assert(sql:create_engine(input, function (engine) -- luacheck: ignore 431/engine
		if needs_upgrade(engine, input) then
			error("Old database format detected. Please run: prosodyctl mod_storage_sql upgrade");
		end
	end));
	local keys = {"host", "user", "store", "key", "type", "value"};
	assert(engine:connect());
	local f,s,val = assert(engine:select("SELECT `host`, `user`, `store`, `key`, `type`, `value` FROM `prosody`;"));
	-- get SQL rows, sorted
	local iter = mtools.sorted {
		reader = function() val = f(s, val); return val; end;
		filter = function(x)
			for i=1,#keys do
				x[ keys[i] ] = x[i];
			end
			if x.host  == "" then x.host  = nil; end
			if x.user  == "" then x.user  = nil; end
			if x.store == "" then x.store = nil; end
			return x;
		end;
		sorter = function(a, b)
			local a_host, a_user, a_store = a.host or "", a.user or "", a.store or "";
			local b_host, b_user, b_store = b.host or "", b.user or "", b.store or "";
			return a_host > b_host or (a_host==b_host and a_user > b_user) or (a_host==b_host and a_user==b_user and a_store > b_store);
		end;
	};
	-- merge rows to get stores
	iter = mtools.merged(iter, function(a, b)
		return (a.host == b.host and a.user == b.user and a.store == b.store);
	end);
	-- merge stores to get users
	iter = mtools.merged(iter, function(a, b)
		return (a[1].host == b[1].host and a[1].user == b[1].user);
	end);
	return function()
		local x = iter();
		return x and decode_user(x);
	end;
end

local function writer(output, iter)
	local engine = assert(sql:create_engine(output, function (engine) -- luacheck: ignore 431/engine
		if needs_upgrade(engine, output) then
			error("Old database format detected. Please run: prosodyctl mod_storage_sql upgrade");
		end
		create_table(engine);
	end));
	assert(engine:connect());
	assert(engine:delete("DELETE FROM prosody"));
	local insert_sql = "INSERT INTO `prosody` (`host`,`user`,`store`,`key`,`type`,`value`) VALUES (?,?,?,?,?,?)";

	return function(item)
		if not item then return end -- end of input
		local host = item.host or "";
		local user = item.user or "";
		for store, data in pairs(item.stores) do
			-- TODO transactions
			local extradata = {};
			for key, value in pairs(data) do
				if type(key) == "string" and key ~= "" then
					local t, value = assert(serialize(value));
					local ok, err = assert(engine:insert(insert_sql, host, user, store, key, t, value));
				else
					extradata[key] = value;
				end
			end
			if next(extradata) ~= nil then
				local t, extradata = assert(serialize(extradata));
				local ok, err = assert(engine:insert(insert_sql, host, user, store, "", t, extradata));
			end
		end
	end;
end


return {
	reader = reader;
	writer = writer;
}
