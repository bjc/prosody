-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local format = string.format;
local setmetatable, type = setmetatable, type;
local pairs, ipairs = pairs, ipairs;
local char = string.char;
local loadfile, setfenv, pcall = loadfile, setfenv, pcall;
local log = require "util.logger".init("datamanager");
local io_open = io.open;
local os_remove = os.remove;
local tostring, tonumber = tostring, tonumber;
local error = error;
local next = next;
local t_insert = table.insert;
local append = require "util.serialization".append;
local path_separator = "/"; if os.getenv("WINDIR") then path_separator = "\\" end
local lfs = require "lfs";
local prosody = prosody;
local raw_mkdir;

if prosody.platform == "posix" then
	raw_mkdir = require "util.pposix".mkdir; -- Doesn't trample on umask
else
	raw_mkdir = lfs.mkdir;
end

module "datamanager"

---- utils -----
local encode, decode;
do
	local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = char(tonumber("0x"..k)); return t[k]; end });

	decode = function (s)
		return s and (s:gsub("+", " "):gsub("%%([a-fA-F0-9][a-fA-F0-9])", urlcodes));
	end

	encode = function (s)
		return s and (s:gsub("%W", function (c) return format("%%%02x", c:byte()); end));
	end
end

local _mkdir = {};
local function mkdir(path)
	path = path:gsub("/", path_separator); -- TODO as an optimization, do this during path creation rather than here
	if not _mkdir[path] then
		raw_mkdir(path);
		_mkdir[path] = true;
	end
	return path;
end

local data_path = (prosody and prosody.paths and prosody.paths.data) or ".";
local callbacks = {};

------- API -------------

function set_data_path(path)
	log("debug", "Setting data path to: %s", path);
	data_path = path;
end

local function callback(username, host, datastore, data)
	for _, f in ipairs(callbacks) do
		username, host, datastore, data = f(username, host, datastore, data);
		if username == false then break; end
	end
	
	return username, host, datastore, data;
end
function add_callback(func)
	if not callbacks[func] then -- Would you really want to set the same callback more than once?
		callbacks[func] = true;
		callbacks[#callbacks+1] = func;
		return true;
	end
end
function remove_callback(func)
	if callbacks[func] then
		for i, f in ipairs(callbacks) do
			if f == func then
				callbacks[i] = nil;
				callbacks[f] = nil;
				return true;
			end
		end
	end
end

function getpath(username, host, datastore, ext, create)
	ext = ext or "dat";
	host = (host and encode(host)) or "_global";
	username = username and encode(username);
	if username then
		if create then mkdir(mkdir(mkdir(data_path).."/"..host).."/"..datastore); end
		return format("%s/%s/%s/%s.%s", data_path, host, datastore, username, ext);
	elseif host then
		if create then mkdir(mkdir(data_path).."/"..host); end
		return format("%s/%s/%s.%s", data_path, host, datastore, ext);
	else
		if create then mkdir(data_path); end
		return format("%s/%s.%s", data_path, datastore, ext);
	end
end

function load(username, host, datastore)
	local data, ret = loadfile(getpath(username, host, datastore));
	if not data then
		local mode = lfs.attributes(getpath(username, host, datastore), "mode");
		if not mode then
			log("debug", "Assuming empty "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
			return nil;
		else -- file exists, but can't be read
			-- TODO more detailed error checking and logging?
			log("error", "Failed to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
			return nil, "Error reading storage";
		end
	end
	setfenv(data, {});
	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil, "Error reading storage";
	end
	return ret;
end

function store(username, host, datastore, data)
	if not data then
		data = {};
	end

	username, host, datastore, data = callback(username, host, datastore, data);
	if username == false then
		return true; -- Don't save this data at all
	end

	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore, nil, true), "w+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil, "Error saving to storage";
	end
	f:write("return ");
	append(f, data);
	f:close();
	if next(data) == nil then -- try to delete empty datastore
		log("debug", "Removing empty %s datastore for user %s@%s", datastore, username or "nil", host or "nil");
		os_remove(getpath(username, host, datastore));
	end
	-- we write data even when we are deleting because lua doesn't have a
	-- platform independent way of checking for non-exisitng files
	return true;
end

function list_append(username, host, datastore, data)
	if not data then return; end
	if callback(username, host, datastore) == false then return true; end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore, "list", true), "a+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return;
	end
	f:write("item(");
	append(f, data);
	f:write(");\n");
	f:close();
	return true;
end

function list_store(username, host, datastore, data)
	if not data then
		data = {};
	end
	if callback(username, host, datastore) == false then return true; end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore, "list", true), "w+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return;
	end
	for _, d in ipairs(data) do
		f:write("item(");
		append(f, d);
		f:write(");\n");
	end
	f:close();
	if next(data) == nil then -- try to delete empty datastore
		log("debug", "Removing empty %s datastore for user %s@%s", datastore, username or "nil", host or "nil");
		os_remove(getpath(username, host, datastore, "list"));
	end
	-- we write data even when we are deleting because lua doesn't have a
	-- platform independent way of checking for non-exisitng files
	return true;
end

function list_load(username, host, datastore)
	local data, ret = loadfile(getpath(username, host, datastore, "list"));
	if not data then
		local mode = lfs.attributes(getpath(username, host, datastore, "list"), "mode");
		if not mode then
			log("debug", "Assuming empty "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
			return nil;
		else -- file exists, but can't be read
			-- TODO more detailed error checking and logging?
			log("error", "Failed to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
			return nil, "Error reading storage";
		end
	end
	local items = {};
	setfenv(data, {item = function(i) t_insert(items, i); end});
	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil, "Error reading storage";
	end
	return items;
end

return _M;
