-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local format = string.format;
local setmetatable = setmetatable;
local ipairs = ipairs;
local char = string.char;
local pcall = pcall;
local log = require "util.logger".init("datamanager");
local io_open = io.open;
local os_remove = os.remove;
local os_rename = os.rename;
local tonumber = tonumber;
local next = next;
local t_insert = table.insert;
local t_concat = table.concat;
local envloadfile = require"util.envload".envloadfile;
local serialize = require "util.serialization".serialize;
local path_separator = assert ( package.config:match ( "^([^\n]+)" ) , "package.config not in standard form" ) -- Extract directory seperator from package.config (an undocumented string that comes with lua)
local lfs = require "lfs";
local prosody = prosody;

local raw_mkdir = lfs.mkdir;
local function fallocate(f, offset, len)
	-- This assumes that current position == offset
	local fake_data = (" "):rep(len);
	local ok, msg = f:write(fake_data);
	if not ok then
		return ok, msg;
	end
	f:seek("set", offset);
	return true;
end;
pcall(function()
	local pposix = require "util.pposix";
	raw_mkdir = pposix.mkdir or raw_mkdir; -- Doesn't trample on umask
	fallocate = pposix.fallocate or fallocate;
end);

local _ENV = nil;

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

local function set_data_path(path)
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
local function add_callback(func)
	if not callbacks[func] then -- Would you really want to set the same callback more than once?
		callbacks[func] = true;
		callbacks[#callbacks+1] = func;
		return true;
	end
end
local function remove_callback(func)
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

local function getpath(username, host, datastore, ext, create)
	ext = ext or "dat";
	host = (host and encode(host)) or "_global";
	username = username and encode(username);
	if username then
		if create then mkdir(mkdir(mkdir(data_path).."/"..host).."/"..datastore); end
		return format("%s/%s/%s/%s.%s", data_path, host, datastore, username, ext);
	else
		if create then mkdir(mkdir(data_path).."/"..host); end
		return format("%s/%s/%s.%s", data_path, host, datastore, ext);
	end
end

local function load(username, host, datastore)
	local data, ret = envloadfile(getpath(username, host, datastore), {});
	if not data then
		local mode = lfs.attributes(getpath(username, host, datastore), "mode");
		if not mode then
			log("debug", "Assuming empty %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
			return nil;
		else -- file exists, but can't be read
			-- TODO more detailed error checking and logging?
			log("error", "Failed to load %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
			return nil, "Error reading storage";
		end
	end

	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
		return nil, "Error reading storage";
	end
	return ret;
end

local function atomic_store(filename, data)
	local scratch = filename.."~";
	local f, ok, msg;
	repeat
		f, msg = io_open(scratch, "w");
		if not f then break end

		ok, msg = f:write(data);
		if not ok then break end

		ok, msg = f:close();
		if not ok then break end

		return os_rename(scratch, filename);
	until false;

	-- Cleanup
	if f then f:close(); end
	os_remove(scratch);
	return nil, msg;
end

if prosody and prosody.platform ~= "posix" then
	-- os.rename does not overwrite existing files on Windows
	-- TODO We could use Transactional NTFS on Vista and above
	function atomic_store(filename, data)
		local f, err = io_open(filename, "w");
		if not f then return f, err; end
		local ok, msg = f:write(data);
		if not ok then f:close(); return ok, msg; end
		return f:close();
	end
end

local function store(username, host, datastore, data)
	if not data then
		data = {};
	end

	username, host, datastore, data = callback(username, host, datastore, data);
	if username == false then
		return true; -- Don't save this data at all
	end

	-- save the datastore
	local d = "return " .. serialize(data) .. ";\n";
	local mkdir_cache_cleared;
	repeat
		local ok, msg = atomic_store(getpath(username, host, datastore, nil, true), d);
		if not ok then
			if not mkdir_cache_cleared then -- We may need to recreate a removed directory
				_mkdir = {};
				mkdir_cache_cleared = true;
			else
				log("error", "Unable to write to %s storage ('%s') for user: %s@%s", datastore, msg, username or "nil", host or "nil");
				return nil, "Error saving to storage";
			end
		end
		if next(data) == nil then -- try to delete empty datastore
			log("debug", "Removing empty %s datastore for user %s@%s", datastore, username or "nil", host or "nil");
			os_remove(getpath(username, host, datastore));
		end
		-- we write data even when we are deleting because lua doesn't have a
		-- platform independent way of checking for non-exisitng files
	until ok;
	return true;
end

local function append(username, host, datastore, ext, data)
	local filename = getpath(username, host, datastore, ext, true);

	local ok;
	local f, msg = io_open(filename, "r+");
	if not f then
		f, msg = io_open(filename, "w");
		if not f then
			return nil, msg;
		end
	end
	local pos = f:seek("end");
	ok, msg = fallocate(f, pos, #data);
	f:seek("set", pos);
	if ok then
		f:write(data);
	else
		return ok, msg;
	end

	ok, msg = f:close();
	if not ok then
		return ok, msg;
	end

	return true;
end

local function list_append(username, host, datastore, data)
	if not data then return; end
	if callback(username, host, datastore) == false then return true; end
	-- save the datastore

	data = "item(" ..  serialize(data) .. ");\n";
	local ok, msg = append(username, host, datastore, "list", data);
	if not ok then
		log("error", "Unable to write to %s storage ('%s') for user: %s@%s", datastore, msg, username or "nil", host or "nil");
		return ok, msg;
	end
	return true;
end

local function list_store(username, host, datastore, data)
	if not data then
		data = {};
	end
	if callback(username, host, datastore) == false then return true; end
	-- save the datastore
	local d = {};
	for _, item in ipairs(data) do
		d[#d+1] = "item(" .. serialize(item) .. ");\n";
	end
	local ok, msg = atomic_store(getpath(username, host, datastore, "list", true), t_concat(d));
	if not ok then
		log("error", "Unable to write to %s storage ('%s') for user: %s@%s", datastore, msg, username or "nil", host or "nil");
		return;
	end
	if next(data) == nil then -- try to delete empty datastore
		log("debug", "Removing empty %s datastore for user %s@%s", datastore, username or "nil", host or "nil");
		os_remove(getpath(username, host, datastore, "list"));
	end
	-- we write data even when we are deleting because lua doesn't have a
	-- platform independent way of checking for non-exisitng files
	return true;
end

local function list_load(username, host, datastore)
	local items = {};
	local data, ret = envloadfile(getpath(username, host, datastore, "list"), {item = function(i) t_insert(items, i); end});
	if not data then
		local mode = lfs.attributes(getpath(username, host, datastore, "list"), "mode");
		if not mode then
			log("debug", "Assuming empty %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
			return nil;
		else -- file exists, but can't be read
			-- TODO more detailed error checking and logging?
			log("error", "Failed to load %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
			return nil, "Error reading storage";
		end
	end

	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
		return nil, "Error reading storage";
	end
	return items;
end

local type_map = {
	keyval = "dat";
	list = "list";
}

local function users(host, store, typ)
	typ = type_map[typ or "keyval"];
	local store_dir = format("%s/%s/%s", data_path, encode(host), store);

	local mode, err = lfs.attributes(store_dir, "mode");
	if not mode then
		return function() log("debug", "%s", err or (store_dir .. " does not exist")) end
	end
	local next, state = lfs.dir(store_dir);
	return function(state)
		for node in next, state do
			local file, ext = node:match("^(.*)%.([dalist]+)$");
			if file and ext == typ then
				return decode(file);
			end
		end
	end, state;
end

local function stores(username, host, typ)
	typ = type_map[typ or "keyval"];
	local store_dir = format("%s/%s/", data_path, encode(host));

	local mode, err = lfs.attributes(store_dir, "mode");
	if not mode then
		return function() log("debug", err or (store_dir .. " does not exist")) end
	end
	local next, state = lfs.dir(store_dir);
	return function(state)
		for node in next, state do
			if not node:match"^%." then
				if username == true then
					if lfs.attributes(store_dir..node, "mode") == "directory" then
						return decode(node);
					end
				elseif username then
					local store = decode(node)
					if lfs.attributes(getpath(username, host, store, typ), "mode") then
						return store;
					end
				elseif lfs.attributes(node, "mode") == "file" then
					local file, ext = node:match("^(.*)%.([dalist]+)$");
					if ext == typ then
						return decode(file)
					end
				end
			end
		end
	end, state;
end

local function do_remove(path)
	local ok, err = os_remove(path);
	if not ok and lfs.attributes(path, "mode") then
		return ok, err;
	end
	return true
end

local function purge(username, host)
	local host_dir = format("%s/%s/", data_path, encode(host));
	local ok, iter, state, var = pcall(lfs.dir, host_dir);
	if not ok then
		return ok, iter;
	end
	local errs = {};
	for file in iter, state, var do
		if lfs.attributes(host_dir..file, "mode") == "directory" then
			local store = decode(file);
			local ok, err = do_remove(getpath(username, host, store));
			if not ok then errs[#errs+1] = err; end

			local ok, err = do_remove(getpath(username, host, store, "list"));
			if not ok then errs[#errs+1] = err; end
		end
	end
	return #errs == 0, t_concat(errs, ", ");
end

return {
	set_data_path = set_data_path;
	add_callback = add_callback;
	remove_callback = remove_callback;
	getpath = getpath;
	load = load;
	store = store;
	list_append = list_append;
	list_store = list_store;
	list_load = list_load;
	users = users;
	stores = stores;
	purge = purge;
	path_decode = decode;
	path_encode = encode;
};
