
module:set_global();

local cache = { data = {} };
function cache:get(key) return self.data[key]; end
function cache:set(key, val) self.data[key] = val; return val; end

local DBI = require "DBI";
function get_database(driver, db, ...)
	local uri = "dbi:"..driver..":"..db;
	return cache:get(uri) or cache:set(uri, (function(...)
		module:log("debug", "Opening database: %s", uri);
		prosody.unlock_globals();
		local dbh = assert(DBI.Connect(...));
		prosody.lock_globals();
		dbh:autocommit(true)
		return dbh;
	end)(driver, db, ...));
end

local st = require "util.stanza";
local _parse_xml = module:require("xmlparse");
parse_xml_real = _parse_xml;
function parse_xml(str)
	local s = _parse_xml(str);
	if s and not s.gsub then
		return st.preserialize(s);
	end
end
function unparse_xml(s)
	return tostring(st.deserialize(s));
end

local drivers = {};

--local driver = module:require("sqlbasic").new("SQLite3", "hello.sqlite");
local option_datastore = module:get_option("datastore");
local option_datastore_params = module:get_option("datastore_params") or {};
if option_datastore then
	local driver = module:require(option_datastore).new(unpack(option_datastore_params));
	table.insert(drivers, driver);
end

local datamanager = require "util.datamanager";
local olddm = {};
local dm = {};
for key,val in pairs(datamanager) do olddm[key] = val; end

do -- driver based on old datamanager
	local dmd = {};
	dmd.__index = dmd;
	function dmd:open(host, datastore)
		return setmetatable({ host = host, datastore = datastore }, dmd);
	end
	function dmd:get(user) return olddm.load(user, self.host, self.datastore); end
	function dmd:set(user, data) return olddm.store(user, self.host, self.datastore, data); end
	table.insert(drivers, dmd);
end

local function open(...)
	for _,driver in pairs(drivers) do
		local ds = driver:open(...);
		if ds then return ds; end
	end
end

local _data_path;
--function dm.set_data_path(path) _data_path = path; end
--function dm.add_callback(...) end
--function dm.remove_callback(...) end
--function dm.getpath(...) end
function dm.load(username, host, datastore)
	local x = open(host, datastore);
	return x:get(username);
end
function dm.store(username, host, datastore, data)
	return open(host, datastore):set(username, data);
end
--function dm.list_append(...) return driver:list_append(...); end
--function dm.list_store(...) return driver:list_store(...); end
--function dm.list_load(...) return driver:list_load(...); end

for key,val in pairs(dm) do datamanager[key] = val; end
