local cache = require "util.cache";
local datamanager = require "core.storagemanager".olddm;
local array = require "util.array";
local datetime = require "util.datetime";
local st = require "util.stanza";
local now = require "util.time".now;
local id = require "util.id".medium;
local jid_join = require "util.jid".join;

local host = module.host;

local archive_item_limit = module:get_option_number("storage_archive_item_limit", 10000);
local archive_item_count_cache = cache.new(module:get_option("storage_archive_item_limit_cache_size", 1000));

local driver = {};

function driver:open(store, typ)
	local mt = self[typ or "keyval"]
	if not mt then
		return nil, "unsupported-store";
	end
	return setmetatable({ store = store, type = typ }, mt);
end

function driver:stores(username) -- luacheck: ignore 212/self
	return datamanager.stores(username, host);
end

function driver:purge(user) -- luacheck: ignore 212/self
	return datamanager.purge(user, host);
end

local keyval = { };
driver.keyval = { __index = keyval };

function keyval:get(user)
	return datamanager.load(user, host, self.store);
end

function keyval:set(user, data)
	return datamanager.store(user, host, self.store, data);
end

function keyval:users()
	return datamanager.users(host, self.store, self.type);
end

local archive = {};
driver.archive = { __index = archive };

archive.caps = {
	total = true;
	quota = archive_item_limit;
	truncate = true;
};

function archive:append(username, key, value, when, with)
	when = when or now();
	if not st.is_stanza(value) then
		return nil, "unsupported-datatype";
	end
	value = st.preserialize(st.clone(value));
	value.when = when;
	value.with = with;
	value.attr.stamp = datetime.datetime(when);
	value.attr.stamp_legacy = datetime.legacy(when);

	local cache_key = jid_join(username, host, self.store);
	local item_count = archive_item_count_cache:get(cache_key);

	if key then
		local items, err = datamanager.list_load(username, host, self.store);
		if not items and err then return items, err; end

		-- Check the quota
		item_count = items and #items or 0;
		archive_item_count_cache:set(cache_key, item_count);
		if item_count >= archive_item_limit then
			module:log("debug", "%s reached or over quota, not adding to store", username);
			return nil, "quota-limit";
		end

		if items then
			-- Filter out any item with the same key as the one being added
			items = array(items);
			items:filter(function (item)
				return item.key ~= key;
			end);

			value.key = key;
			items:push(value);
			local ok, err = datamanager.list_store(username, host, self.store, items);
			if not ok then return ok, err; end
			archive_item_count_cache:set(cache_key, #items);
			return key;
		end
	else
		if not item_count then -- Item count not cached?
			-- We need to load the list to get the number of items currently stored
			local items, err = datamanager.list_load(username, host, self.store);
			if not items and err then return items, err; end
			item_count = items and #items or 0;
			archive_item_count_cache:set(cache_key, item_count);
		end
		if item_count >= archive_item_limit then
			module:log("debug", "%s reached or over quota, not adding to store", username);
			return nil, "quota-limit";
		end
		key = id();
	end

	module:log("debug", "%s has %d items out of %d limit in store %s", username, item_count, archive_item_limit, self.store);

	value.key = key;

	local ok, err = datamanager.list_append(username, host, self.store, value);
	if not ok then return ok, err; end
	archive_item_count_cache:set(cache_key, item_count+1);
	return key;
end

function archive:find(username, query)
	local items, err = datamanager.list_load(username, host, self.store);
	if not items then
		if err then
			return items, err;
		elseif query then
			if query.before or query.after then
				return nil, "item-not-found";
			end
			if query.total then
				return function () end, 0;
			end
		end
		return function () end;
	end
	local count = nil;
	local i = 0;
	if query then
		items = array(items);
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
		if query.total then
			count = #items;
		end
		if query.reverse then
			items:reverse();
			if query.before then
				local found = false;
				for j = 1, #items do
					if (items[j].key or tostring(j)) == query.before then
						found = true;
						i = j;
						break;
					end
				end
				if not found then
					return nil, "item-not-found";
				end
			end
		elseif query.after then
			local found = false;
			for j = 1, #items do
				if (items[j].key or tostring(j)) == query.after then
					found = true;
					i = j;
					break;
				end
			end
			if not found then
				return nil, "item-not-found";
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
		local key = item.key or tostring(i);
		local when = item.when or datetime.parse(item.attr.stamp);
		local with = item.with;
		item.key, item.when, item.with = nil, nil, nil;
		item.attr.stamp = nil;
		item.attr.stamp_legacy = nil;
		item = st.deserialize(item);
		return key, item, when, with;
	end, count;
end

function archive:dates(username)
	local items, err = datamanager.list_load(username, host, self.store);
	if not items then return items, err; end
	return array(items):pluck("when"):map(datetime.date):unique();
end

function archive:summary(username, query)
	local iter, err = self:find(username, query)
	if not iter then return iter, err; end
	local counts = {};
	local latest = {};
	for _, _, when, with in iter do
		counts[with] = (counts[with] or 0) + 1;
		latest[with] = when;
	end
	return {
		counts = counts;
		latest = latest;
	};
end

function archive:users()
	return datamanager.users(host, self.store, "list");
end

function archive:delete(username, query)
	local cache_key = jid_join(username, host, self.store);
	if not query or next(query) == nil then
		archive_item_count_cache:set(cache_key, nil);
		return datamanager.list_store(username, host, self.store, nil);
	end
	local items, err = datamanager.list_load(username, host, self.store);
	if not items then
		if err then
			return items, err;
		end
		archive_item_count_cache:set(cache_key, 0);
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
	local ok, err = datamanager.list_store(username, host, self.store, items);
	if not ok then return ok, err; end
	archive_item_count_cache:set(cache_key, #items);
	return count;
end

module:provides("storage", driver);
