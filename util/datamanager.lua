-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local string = string;
local format = string.format;
local setmetatable = setmetatable;
local ipairs = ipairs;
local char = string.char;
local pcall = pcall;
local log = require "prosody.util.logger".init("datamanager");
local io_open = io.open;
local os_remove = os.remove;
local os_rename = os.rename;
local tonumber = tonumber;
local floor = math.floor;
local next = next;
local type = type;
local t_insert = table.insert;
local t_concat = table.concat;
local envloadfile = require"prosody.util.envload".envloadfile;
local envload = require"prosody.util.envload".envload;
local serialize = require "prosody.util.serialization".serialize;
local lfs = require "lfs";
-- Extract directory separator from package.config (an undocumented string that comes with lua)
local path_separator = assert ( package.config:match ( "^([^\n]+)" ) , "package.config not in standard form" )

local prosody = prosody;

--luacheck: ignore 211/blocksize 211/remove_blocks
local blocksize = 0x1000;
local raw_mkdir = lfs.mkdir;
local atomic_append;
local remove_blocks;
local ENOENT = 2;
pcall(function()
	local pposix = require "prosody.util.pposix";
	raw_mkdir = pposix.mkdir or raw_mkdir; -- Doesn't trample on umask
	atomic_append = pposix.atomic_append;
	-- remove_blocks = pposix.remove_blocks;
	ENOENT = pposix.ENOENT or ENOENT;
end);

local _ENV = nil;
-- luacheck: std none

---- utils -----
local encode, decode, store_encode;
do
	local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = char(tonumber(k, 16)); return t[k]; end });

	decode = function (s)
		return s and (s:gsub("%%(%x%x)", urlcodes));
	end

	encode = function (s)
		return s and (s:gsub("%W", function (c) return format("%%%02x", c:byte()); end));
	end

	-- Special encode function for store names, which historically were unencoded.
	-- All currently known stores use a-z and underscore, so this one preserves underscores.
	store_encode = function (s)
		return s and (s:gsub("[^_%w]", function (c) return format("%%%02x", c:byte()); end));
	end
end

if not atomic_append then
	function atomic_append(f, data)
		local pos = f:seek();
		if not f:write(data) or not f:flush() then
			f:seek("set", pos);
			f:write((" "):rep(#data));
			f:flush();
			return nil, "write-failed";
		end
		return true;
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
	datastore = store_encode(datastore);
	if username then
		if create then mkdir(mkdir(mkdir(data_path).."/"..host).."/"..datastore); end
		return format("%s/%s/%s/%s.%s", data_path, host, datastore, username, ext);
	else
		if create then mkdir(mkdir(data_path).."/"..host); end
		return format("%s/%s/%s.%s", data_path, host, datastore, ext);
	end
end

local function load(username, host, datastore)
	local data, err, errno = envloadfile(getpath(username, host, datastore), {});
	if not data then
		if errno == ENOENT then
			-- No such file, ok to ignore
			return nil;
		end
		log("error", "Failed to load %s storage ('%s') for user: %s@%s", datastore, err, username or "nil", host or "nil");
		return nil, "Error reading storage";
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
	local f, ok, msg, errno; -- luacheck: ignore errno
	-- TODO return util.error with code=errno?

	f, msg, errno = io_open(scratch, "w");
	if not f then
		return nil, msg;
	end

	ok, msg = f:write(data);
	if not ok then
		f:close();
		os_remove(scratch);
		return nil, msg;
	end

	ok, msg = f:close();
	if not ok then
		os_remove(scratch);
		return nil, msg;
	end

	return os_rename(scratch, filename);
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
		-- platform independent way of checking for nonexisting files
	until ok;
	return true;
end

-- Append a blob of data to a file
local function append(username, host, datastore, ext, data)
	if type(data) ~= "string" then return; end
	local filename = getpath(username, host, datastore, ext, true);

	local f = io_open(filename, "r+");
	if not f then
		return atomic_store(filename, data);
		-- File did probably not exist, let's create it
	end

	local pos = f:seek("end");
	--[[ TODO needs tests
	if (blocksize-(pos%blocksize)) < (#data%blocksize) then
		-- pad to blocksize with newlines so that the next item is both on a new
		-- block and a new line
		atomic_append(f, ("\n"):rep(blocksize-(pos%blocksize)));
		pos = f:seek("end");
	end
	--]]

	local ok, msg = atomic_append(f, data);

	if not ok then
		f:close();
		return ok, msg, "write";
	end

	ok, msg = f:close();
	if not ok then
		return ok, msg, "close";
	end

	return true, pos;
end

local index_fmt, index_item_size, index_magic;
if string.packsize then
	index_fmt = "T"; -- offset to the end of the item, length can be derived from two index items
	index_item_size = string.packsize(index_fmt);
	index_magic = string.pack(index_fmt, 7767639 + 1); -- Magic string: T9 for "prosody", version number
end

local function list_append(username, host, datastore, data)
	if not data then return; end
	if callback(username, host, datastore) == false then return true; end
	-- save the datastore

	data = "item(" ..  serialize(data) .. ");\n";
	local ok, msg, where = append(username, host, datastore, "list", data);
	if not ok then
		log("error", "Unable to write to %s storage ('%s' in %s) for user: %s@%s",
			datastore, msg, where, username or "nil", host or "nil");
		return ok, msg;
	end
	if string.packsize then
		local offset = type(msg) == "number" and msg or 0;
		local index_entry = string.pack(index_fmt, offset + #data);
		if offset == 0 then
			index_entry = index_magic .. index_entry;
		end
		local ok, off = append(username, host, datastore, "lidx", index_entry);
		off = off or 0;
		-- If this was the first item, then both the data and index offsets should
		-- be zero, otherwise there's some kind of mismatch and we should drop the
		-- index and recreate it from scratch
		-- TODO Actually rebuild the index in this case?
		if not ok or (off == 0 and offset ~= 0) or (off ~= 0 and offset == 0) then
			os_remove(getpath(username, host, datastore, "lidx"));
		end
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
	for i, item in ipairs(data) do
		d[i] = "item(" .. serialize(item) .. ");\n";
	end
	os_remove(getpath(username, host, datastore, "lidx"));
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
	-- platform independent way of checking for nonexisting files
	return true;
end

local function build_list_index(username, host, datastore, items)
	log("debug", "Building index for (%s@%s/%s)", username, host, datastore);
	local filename = getpath(username, host, datastore, "list");
	local fh, err, errno = io_open(filename);
	if not fh then
		return fh, err, errno;
	end
	local prev_pos = 0; -- position before reading
	local last_item_start = nil;

	if items and items[1] then
		local last_item = items[#items];
		last_item_start = fh:seek("set", last_item.start + last_item.length);
	else
		items = {};
	end

	for line in fh:lines() do
		if line:sub(1, 4) == "item" then
			if prev_pos ~= 0 and last_item_start then
				t_insert(items, { start = last_item_start; length = prev_pos - last_item_start });
			end
			last_item_start = prev_pos
		end
		-- seek position is at the start of the next line within each loop iteration
		-- so we need to collect the "current" position at the end of the previous
		prev_pos = fh:seek()
	end
	fh:close();
	if prev_pos ~= 0 then
		t_insert(items, { start = last_item_start; length = prev_pos - last_item_start });
	end
	return items;
end

local function store_list_index(username, host, datastore, index)
	local data = { index_magic };
	for i, v in ipairs(index) do
		data[i + 1] = string.pack(index_fmt, v.start + v.length);
	end
	local filename = getpath(username, host, datastore, "lidx");
	return atomic_store(filename, t_concat(data));
end

local index_mt = {
	__index = function(t, i)
		if type(i) ~= "number" or i % 1 ~= 0 or i < 0 then
			return
		end
		if i <= 0 then
			return 0
		end
		local fh = t.file;
		local pos = (i - 1) * index_item_size;
		if fh:seek("set", pos) ~= pos then
			return nil
		end
		local data = fh:read(index_item_size * 2);
		if not data or #data ~= index_item_size * 2 then
			return nil
		end
		local start, next_pos = string.unpack(index_fmt .. index_fmt, data);
		if pos == 0 then
			start = 0
		end
		local length = next_pos - start;
		local v = { start = start; length = length };
		t[i] = v;
		return v;
	end;
	__len = function(t)
		-- Account for both the header and the fence post error
		return floor(t.file:seek("end") / index_item_size) - 1;
	end;
}

local function get_list_index(username, host, datastore)
	log("debug", "Loading index for (%s@%s/%s)", username, host, datastore);
	local index_filename = getpath(username, host, datastore, "lidx");
	local ih = io_open(index_filename);
	if ih then
		local magic = ih:read(#index_magic);
		if magic ~= index_magic then
			log("debug", "Index %q has wrong version number (got %q, expected %q), rebuilding...", index_filename, magic, index_magic);
			-- wrong version or something
			ih:close();
			ih = nil;
		end
	end

	if ih then
		local first_length = string.unpack(index_fmt, ih:read(index_item_size));
		return setmetatable({ file = ih; { start = 0; length = first_length } }, index_mt);
	end

	local index, err = build_list_index(username, host, datastore);
	if not index then
		return index, err
	end

	-- TODO How to handle failure to store the index?
	local dontcare = store_list_index(username, host, datastore, index); -- luacheck: ignore 211/dontcare
	return index;
end

local function list_load_one(fh, start, length)
	if fh:seek("set", start) ~= start then
		return nil
	end
	local raw_data = fh:read(length)
	if not raw_data or #raw_data ~= length then
		return
	end
	local item;
	local data, err, errno = envload(raw_data, "@list", {
		item = function(i)
			item = i;
		end;
	});
	if not data then
		return data, err, errno
	end
	local success, ret = pcall(data);
	if not success then
		return success, ret;
	end
	return item;
end

local function list_close(list)
	if list.index and list.index.file then
		list.index.file:close();
	end
	return list.file:close();
end

local indexed_list_mt = {
	__index = function(t, i)
		if type(i) ~= "number" or i % 1 ~= 0 or i < 1 then
			return
		end
		local ix = t.index[i];
		if not ix then
			return
		end
		local item = list_load_one(t.file, ix.start, ix.length);
		return item;
	end;
	__len = function(t)
		return #t.index;
	end;
	__close = list_close;
}

local function list_load(username, host, datastore)
	local items = {};
	local data, err, errno = envloadfile(getpath(username, host, datastore, "list"), {item = function(i) t_insert(items, i); end});
	if not data then
		if errno == ENOENT then
			-- No such file, ok to ignore
			return nil;
		end
		log("error", "Failed to load %s storage ('%s') for user: %s@%s", datastore, err, username or "nil", host or "nil");
		return nil, "Error reading storage";
	end

	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load %s storage ('%s') for user: %s@%s", datastore, ret, username or "nil", host or "nil");
		return nil, "Error reading storage";
	end
	return items;
end

local function list_open(username, host, datastore)
	if not index_magic then
		log("debug", "Falling back from lazy loading to loading full list for %s storage for user: %s@%s", datastore, username or "nil", host or "nil");
		return list_load(username, host, datastore);
	end
	local filename = getpath(username, host, datastore, "list");
	local file, err, errno = io_open(filename);
	if not file then
		if errno == ENOENT then
			return nil;
		end
		return file, err, errno;
	end
	local index, err = get_list_index(username, host, datastore);
	if not index then
		file:close()
		return index, err;
	end
	return setmetatable({ file = file; index = index; close = list_close }, indexed_list_mt);
end

local function shift_index(index_filename, index, trim_to, offset) -- luacheck: ignore 212
	os_remove(index_filename);
	return "deleted";
	-- TODO move and recalculate remaining items
end

local function list_shift(username, host, datastore, trim_to)
	if trim_to == 1 then
		return true
	end
	if type(trim_to) ~= "number" or trim_to < 1 then
		return nil, "invalid-argument";
	end
	local list_filename = getpath(username, host, datastore, "list");
	local index_filename = getpath(username, host, datastore, "lidx");
	local index, err = get_list_index(username, host, datastore);
	if not index then
		return nil, err;
	end

	local new_first = index[trim_to];
	if not new_first then
		os_remove(index_filename);
		return os_remove(list_filename);
	end

	local offset = new_first.start;
	if offset == 0 then
		return true;
	end

	--[[
	if remove_blocks then
		local f, err = io_open(list_filename, "r+");
		if not f then
			return f, err;
		end

		local diff = 0;
		local block_offset = 0;
		if offset % 0x1000 ~= 0 then
			-- Not an even block boundary, we will have to overwrite
			diff = offset % 0x1000;
			block_offset = offset - diff;
		end

		if block_offset == 0 then
			log("debug", "")
		else
			local ok, err = remove_blocks(f, 0, block_offset);
			log("debug", "remove_blocks(%s, 0, %d)", f, block_offset);
			if not ok then
				log("warn", "Could not remove blocks from %q[%d, %d]: %s", list_filename, 0, block_offset, err);
			else
				if diff ~= 0 then
					-- overwrite unaligned leftovers
					if f:seek("set", 0) then
						local wrote, err = f:write(string.rep("\n", diff));
						if not wrote then
							log("error", "Could not blank out %q[%d, %d]: %s", list_filename, 0, diff, err);
						end
					end
				end
				local ok, err = f:close();
				shift_index(index_filename, index, trim_to, offset); -- Shift or delete the index
				return ok, err;
			end
		end
	end
	--]]

	local r, err = io_open(list_filename, "r");
	if not r then
		return nil, err;
	end
	local w, err = io_open(list_filename .. "~", "w");
	if not w then
		return nil, err;
	end
	r:seek("set", offset);
	for block in r:lines(0x1000) do
		local ok, err = w:write(block);
		if not ok then
			return nil, err;
		end
	end
	r:close();
	local ok, err = w:close();
	if not ok then
		return nil, err;
	end
	shift_index(index_filename, index, trim_to, offset)
	return os_rename(list_filename .. "~", list_filename);
end


local type_map = {
	keyval = "dat";
	list = "list";
}

local function users(host, store, typ) -- luacheck: ignore 431/store
	typ = "."..(type_map[typ or "keyval"] or typ);
	local store_dir = format("%s/%s/%s", data_path, encode(host), store_encode(store));

	local mode, err = lfs.attributes(store_dir, "mode");
	if not mode then
		return function() log("debug", "%s", err or (store_dir .. " does not exist")) end
	end
	local next, state = lfs.dir(store_dir); -- luacheck: ignore 431/next 431/state
	return function(state) -- luacheck: ignore 431/state
		for node in next, state do
			if node:sub(-#typ, -1) == typ then
				return decode(node:sub(1, -#typ-1));
			end
		end
	end, state;
end

local function stores(username, host, typ)
	typ = type_map[typ or "keyval"];
	local store_dir = format("%s/%s/", data_path, encode(host));

	local mode, err = lfs.attributes(store_dir, "mode");
	if not mode then
		return function() log("debug", "Could not iterate over stores in %s: %s", store_dir, err); end
	end
	local next, state = lfs.dir(store_dir); -- luacheck: ignore 431/next 431/state
	return function(state) -- luacheck: ignore 431/state
		for node in next, state do
			if not node:match"^%." then
				if username == true then
					if lfs.attributes(store_dir..node, "mode") == "directory" then
						return decode(node);
					end
				elseif username then
					local store_name = decode(node);
					if lfs.attributes(getpath(username, host, store_name, typ), "mode") then
						return store_name;
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
			local store_name = decode(file);
			local ok, err = do_remove(getpath(username, host, store_name));
			if not ok then errs[#errs+1] = err; end

			local ok, err = do_remove(getpath(username, host, store_name, "list"));
			if not ok then errs[#errs+1] = err; end
			local ok, err = do_remove(getpath(username, host, store_name, "lidx"));
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
	append_raw = append;
	store_raw = atomic_store;
	list_append = list_append;
	list_store = list_store;
	list_load = list_load;
	users = users;
	stores = stores;
	purge = purge;
	path_decode = decode;
	path_encode = encode;

	build_list_index = build_list_index;
	list_open = list_open;
	list_shift = list_shift;
};
