local serialize = require "util.serialization".serialize;
local array = require "util.array";
local envload = require "util.envload".envload;
local st = require "util.stanza";
local is_stanza = st.is_stanza or function (s) return getmetatable(s) == st.stanza_mt end
local new_id = require "util.id".medium;

local auto_purge_enabled = module:get_option_boolean("storage_memory_temporary", false);
local auto_purge_stores = module:get_option_set("storage_memory_temporary_stores", {});

local memory = setmetatable({}, {
	__index = function(t, k)
		local store = module:shared(k)
		t[k] = store;
		return store;
	end
});

local function NULL() return nil end

local function _purge_store(self, username)
	self.store[username or NULL] = nil;
	return true;
end

local function _users(self)
	return next, self.store, nil;
end

local keyval_store = {};
keyval_store.__index = keyval_store;

function keyval_store:get(username)
	return (self.store[username or NULL] or NULL)();
end

function keyval_store:set(username, data)
	if data ~= nil then
		data = envload("return "..serialize(data), "=(data)", {});
	end
	self.store[username or NULL] = data;
	return true;
end

keyval_store.purge = _purge_store;

keyval_store.users = _users;

local archive_store = {};
archive_store.__index = archive_store;

archive_store.users = _users;

function archive_store:append(username, key, value, when, with)
	if is_stanza(value) then
		value = st.preserialize(value);
		value = envload("return xml"..serialize(value), "=(stanza)", { xml = st.deserialize })
	else
		value = envload("return "..serialize(value), "=(data)", {});
	end
	local a = self.store[username or NULL];
	if not a then
		a = {};
		self.store[username or NULL] = a;
	end
	local v = { key = key, when = when, with = with, value = value };
	if not key then
		key = new_id();
		v.key = key;
	end
	if a[key] then
		table.remove(a, a[key]);
	end
	local i = #a+1;
	a[i] = v;
	a[key] = i;
	return key;
end

function archive_store:find(username, query)
	local items = self.store[username or NULL];
	if not items then
		return function () end, 0;
	end
	local count = #items;
	local i = 0;
	if query then
		items = array():append(items);
		if query.key then
			items:filter(function (item)
				return item.key == query.key;
			end);
		end
		if query.with then
			items:filter(function (item)
				return item.with == query.with;
			end);
		end
		if query.start then
			items:filter(function (item)
				return item.when >= query.start;
			end);
		end
		if query["end"] then
			items:filter(function (item)
				return item.when <= query["end"];
			end);
		end
		count = #items;
		if query.reverse then
			items:reverse();
			if query.before then
				for j = 1, count do
					if (items[j].key or tostring(j)) == query.before then
						i = j;
						break;
					end
				end
			end
		elseif query.after then
			for j = 1, count do
				if (items[j].key or tostring(j)) == query.after then
					i = j;
					break;
				end
			end
		end
		if query.limit and #items - i > query.limit then
			items[i+query.limit+1] = nil;
		end
	end
	return function ()
		i = i + 1;
		local item = items[i];
		if not item then return; end
		return item.key, item.value(), item.when, item.with;
	end, count;
end


function archive_store:delete(username, query)
	if not query or next(query) == nil then
		self.store[username or NULL] = nil;
		return true;
	end
	local items = self.store[username or NULL];
	if not items then
		-- Store is empty
		return 0;
	end
	items = array(items);
	local count_before = #items;
	if query then
		if query.key then
			items:filter(function (item)
				return item.key ~= query.key;
			end);
		end
		if query.with then
			items:filter(function (item)
				return item.with ~= query.with;
			end);
		end
		if query.start then
			items:filter(function (item)
				return item.when < query.start;
			end);
		end
		if query["end"] then
			items:filter(function (item)
				return item.when > query["end"];
			end);
		end
		if query.truncate and #items > query.truncate then
			if query.reverse then
				-- Before: { 1, 2, 3, 4, 5, }
				-- After: { 1, 2, 3 }
				for i = #items, query.truncate + 1, -1 do
					items[i] = nil;
				end
			else
				-- Before: { 1, 2, 3, 4, 5, }
				-- After: { 3, 4, 5 }
				local offset = #items - query.truncate;
				for i = 1, #items do
					items[i] = items[i+offset];
				end
			end
		end
	end
	local count = count_before - #items;
	if count == 0 then
		return 0; -- No changes, skip write
	end
	setmetatable(items, nil);

	do -- re-index by key
		for k in pairs(items) do
			if type(k) == "string" then
				items[k] = nil;
			end
		end

		for i = 1, #items do
			items[ items[i].key ] = i;
		end
	end

	return count;
end

archive_store.purge = _purge_store;

local stores = {
	keyval = keyval_store;
	archive = archive_store;
}

local driver = {};

function driver:open(store, typ) -- luacheck: ignore 212/self
	local store_mt = stores[typ or "keyval"];
	if store_mt then
		return setmetatable({ store = memory[store] }, store_mt);
	end
	return nil, "unsupported-store";
end

function driver:purge(user) -- luacheck: ignore 212/self
	for _, store in pairs(memory) do
		store[user] = nil;
	end
end

if auto_purge_enabled then
	module:hook("resource-unbind", function (event)
		local user_bare_jid = event.session.username.."@"..event.session.host;
		if not prosody.bare_sessions[user_bare_jid] then -- User went offline
			module:log("debug", "Clearing store for offline user %s", user_bare_jid);
			local f, s, v;
			if auto_purge_stores:empty() then
				f, s, v = pairs(memory);
			else
				f, s, v = auto_purge_stores:items();
			end

			for store_name in f, s, v do
				if memory[store_name] then
					memory[store_name][event.session.username] = nil;
				end
			end
		end
	end);
end

module:provides("storage", driver);
