
local print = print;
local assert = assert;
local setmetatable = setmetatable;
local tonumber = tonumber;
local char = string.char;
local coroutine = coroutine;
local lfs = require "lfs";
local loadfile = loadfile;
local pcall = pcall;
local mtools = require "migrator.mtools";
local next = next;
local pairs = pairs;
local json = require "util.json";
local os_getenv = os.getenv;

prosody = {};
local dm = require "util.datamanager"

module "prosody_files"

local function is_dir(path) return lfs.attributes(path, "mode") == "directory"; end
local function is_file(path) return lfs.attributes(path, "mode") == "file"; end
local function clean_path(path)
	return path:gsub("\\", "/"):gsub("//+", "/"):gsub("^~", os_getenv("HOME") or "~");
end
local encode, decode; do
	local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = char(tonumber("0x"..k)); return t[k]; end });
	decode = function (s) return s and (s:gsub("+", " "):gsub("%%([a-fA-F0-9][a-fA-F0-9])", urlcodes)); end
	encode = function (s) return s and (s:gsub("%W", function (c) return format("%%%02x", c:byte()); end)); end
end
local function decode_dir(x)
	if x:gsub("%%%x%x", ""):gsub("[a-zA-Z0-9]", "") == "" then
		return decode(x);
	end
end
local function decode_file(x)
	if x:match(".%.dat$") and x:gsub("%.dat$", ""):gsub("%%%x%x", ""):gsub("[a-zA-Z0-9]", "") == "" then
		return decode(x:gsub("%.dat$", ""));
	end
end
local function prosody_dir(path, ondir, onfile, ...)
	for x in lfs.dir(path) do
		local xpath = path.."/"..x;
		if decode_dir(x) and is_dir(xpath) then
			ondir(xpath, x, ...);
		elseif decode_file(x) and is_file(xpath) then
			onfile(xpath, x, ...);
		end
	end
end

local function handle_root_file(path, name)
	--print("root file: ", decode_file(name))
	coroutine.yield { user = nil, host = nil, store = decode_file(name) };
end
local function handle_host_file(path, name, host)
	--print("host file: ", decode_dir(host).."/"..decode_file(name))
	coroutine.yield { user = nil, host = decode_dir(host), store = decode_file(name) };
end
local function handle_store_file(path, name, store, host)
	--print("store file: ", decode_file(name).."@"..decode_dir(host).."/"..decode_dir(store))
	coroutine.yield { user = decode_file(name), host = decode_dir(host), store = decode_dir(store) };
end
local function handle_host_store(path, name, host)
	prosody_dir(path, function() end, handle_store_file, name, host);
end
local function handle_host_dir(path, name)
	prosody_dir(path, handle_host_store, handle_host_file, name);
end
local function handle_root_dir(path)
	prosody_dir(path, handle_host_dir, handle_root_file);
end

local function decode_user(item)
	local userdata = {
		user = item[1].user;
		host = item[1].host;
		stores = {};
	};
	for i=1,#item do -- loop over stores
		local result = {};
		local store = item[i];
		userdata.stores[store.store] = store.data;
		store.user = nil; store.host = nil; store.store = nil;
	end
	return userdata;
end

function reader(input)
	local path = clean_path(assert(input.path, "no input.path specified"));
	assert(is_dir(path), "input.path is not a directory");
	local iter = coroutine.wrap(function()handle_root_dir(path);end);
	-- get per-user stores, sorted
	local iter = mtools.sorted {
		reader = function()
			local x = iter();
			if x then
				dm.set_data_path(path);
				local err;
				x.data, err = dm.load(x.user, x.host, x.store);
				if x.data == nil and err then
					error(("Error loading data at path %s for %s@%s (%s store)")
						:format(path, x.user or "<nil>", x.host or "<nil>", x.store or "<nil>"), 0);
				end
				return x;
			end
		end;
		sorter = function(a, b)
			local a_host, a_user, a_store = a.host or "", a.user or "", a.store or "";
			local b_host, b_user, b_store = b.host or "", b.user or "", b.store or "";
			return a_host > b_host or (a_host==b_host and a_user > b_user) or (a_host==b_host and a_user==b_user and a_store > b_store);
		end;
	};
	-- merge stores to get users
	iter = mtools.merged(iter, function(a, b)
		return (a.host == b.host and a.user == b.user);
	end);

	return function()
		local x = iter();
		return x and decode_user(x);
	end
end

function writer(output)
	local path = clean_path(assert(output.path, "no output.path specified"));
	assert(is_dir(path), "output.path is not a directory");
	return function(item)
		if not item then return; end -- end of input
		dm.set_data_path(path);
		for store, data in pairs(item.stores) do
			assert(dm.store(item.user, item.host, store, data));
		end
	end
end

return _M;
