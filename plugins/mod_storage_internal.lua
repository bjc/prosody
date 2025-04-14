local cache = require "prosody.util.cache";
local datamanager = require "prosody.core.storagemanager".olddm;
local array = require "prosody.util.array";
local datetime = require "prosody.util.datetime";
local st = require "prosody.util.stanza";
local now = require "prosody.util.time".now;
local uuid_v7 = require "prosody.util.uuid".v7;
local jid_join = require "prosody.util.jid".join;
local set = require "prosody.util.set";
local it = require "prosody.util.iterators";

local host = module.host;

local archive_item_limit = module:get_option_integer("storage_archive_item_limit", 10000, 0);
local archive_item_count_cache = cache.new(module:get_option_integer("storage_archive_item_limit_cache_size", 1000, 1));

local use_shift = module:get_option_boolean("storage_archive_experimental_fast_delete", false);

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
	full_id_range = true;
	ids = true;
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
		key = uuid_v7();
	end

	module:log("debug", "%s has %d items out of %d limit in store %s", username, item_count, archive_item_limit, self.store);

	value.key = key;

	local ok, err = datamanager.list_append(username, host, self.store, value);
	if not ok then return ok, err; end
	archive_item_count_cache:set(cache_key, item_count+1);
	return key;
end

local function binary_search(haystack, test, min, max)
	if min == nil then
		min = 1;
	end
	if max == nil then
		max = #haystack;
	end

	local floor = math.floor;
	while min < max do
		local mid = floor((max + min) / 2);

		local result = test(haystack[mid]);
		if result < 0 then
			max = mid;
		elseif result > 0 then
			min = mid + 1;
		else
			return mid, haystack[mid];
		end
	end

	return min, nil;
end

function archive:find(username, query)
	local list, err = datamanager.list_open(username, host, self.store);
	if not list then
		if err then
			return list, err;
		elseif query then
			if query.before or query.after then
				return nil, "item-not-found";
			end
			if query.total then
				return function()
				end, 0;
			end
		end
		return function()
		end;
	end

	local i = 0;
	local iter = function()
		i = i + 1;
		return list[i]
	end

	if query then
		if query.reverse then
			i = #list + 1
			iter = function()
				i = i - 1
				return list[i]
			end
			query.before, query.after = query.after, query.before;
		end
		if query.key then
			iter = it.filter(function(item)
				return item.key == query.key;
			end, iter);
		end
		if query.ids then
			local ids = set.new(query.ids);
			iter = it.filter(function(item)
				return ids:contains(item.key);
			end, iter);
		end
		if query.with then
			iter = it.filter(function(item)
				return item.with == query.with;
			end, iter);
		end
		if query.start then
			if not query.reverse then
				local wi = binary_search(list, function(item)
					local when = item.when or datetime.parse(item.attr.stamp);
					return query.start - when;
				end);
				i = wi - 1;
			end
			iter = it.filter(function(item)
				local when = item.when or datetime.parse(item.attr.stamp);
				return when >= query.start;
			end, iter);
		end
		if query["end"] then
			if query.reverse then
				local wi = binary_search(list, function(item)
					local when = item.when or datetime.parse(item.attr.stamp);
					return query["end"] - when;
				end);
				if wi then
					i = wi + 1;
				end
			end
			iter = it.filter(function(item)
				local when = item.when or datetime.parse(item.attr.stamp);
				return when <= query["end"];
			end, iter);
		end
		if query.after then
			local found = false;
			iter = it.filter(function(item)
				local found_after = found;
				if item.key == query.after then
					found = true
				end
				return found_after;
			end, iter);
		end
		if query.before then
			local found = false;
			iter = it.filter(function(item)
				if item.key == query.before then
					found = true
				end
				return not found;
			end, iter);
		end
		if query.limit then
			iter = it.head(query.limit, iter);
		end
	end

	return function()
		local item = iter();
		if item == nil then
			if list.close then
				list:close();
			end
			return
		end
		local key = item.key;
		local when = item.when or item.attr and datetime.parse(item.attr.stamp);
		local with = item.with;
		item.key, item.when, item.with = nil, nil, nil;
		item.attr.stamp = nil;
		-- COMPAT Stored data may still contain legacy XEP-0091 timestamp
		item.attr.stamp_legacy = nil;
		item = st.deserialize(item);
		return key, item, when, with;
	end
end

function archive:get(username, wanted_key)
	local iter, err = self:find(username, { key = wanted_key })
	if not iter then return iter, err; end
	for key, stanza, when, with in iter do
		if key == wanted_key then
			return stanza, when, with;
		end
	end
	return nil, "item-not-found";
end

function archive:set(username, key, new_value, new_when, new_with)
	local items, err = datamanager.list_load(username, host, self.store);
	if not items then
		if err then
			return items, err;
		else
			return nil, "item-not-found";
		end
	end

	for i = 1, #items do
		local old_item = items[i];
		if old_item.key == key then
			local item = st.preserialize(st.clone(new_value));

			local when = new_when or old_item.when or datetime.parse(old_item.attr.stamp);
			item.key = key;
			item.when = when;
			item.with = new_with or old_item.with;
			item.attr.stamp = datetime.datetime(when);
			items[i] = item;
			return datamanager.list_store(username, host, self.store, items);
		end
	end

	return nil, "item-not-found";
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
	local earliest = {};
	local latest = {};
	local body = {};
	for _, stanza, when, with in iter do
		counts[with] = (counts[with] or 0) + 1;
		if earliest[with] == nil then
			earliest[with] = when;
		end
		latest[with] = when;
		body[with] = stanza:get_child_text("body") or body[with];
	end
	return {
		counts = counts;
		earliest = earliest;
		latest = latest;
		body = body;
	};
end

function archive:users()
	return datamanager.users(host, self.store, "list");
end

function archive:trim(username, to_when)
	local cache_key = jid_join(username, host, self.store);
	local list, err = datamanager.list_open(username, host, self.store);
	if not list then
		if err == nil then
			module:log("debug", "store already empty, can't trim");
			return 0;
		end
		return list, err;
	end

	-- shortcut: check if the last item should be trimmed, if so, drop the whole archive
	local last = list[#list].when or datetime.parse(list[#list].attr.stamp);
	if last <= to_when then
		if list.close then
			list:close()
		end
		return datamanager.list_store(username, host, self.store, nil);
	end

	-- luacheck: ignore 211/exact
	local i, exact = binary_search(list, function(item)
		local when = item.when or datetime.parse(item.attr.stamp);
		return to_when - when;
	end);
	if list.close then
		list:close()
	end
	-- TODO if exact then ... off by one?
	if i == 1 then return 0; end
	local ok, err = datamanager.list_shift(username, host, self.store, i);
	if not ok then return ok, err; end
	archive_item_count_cache:set(cache_key, nil); -- TODO calculate how many items are left
	return i-1;
end

function archive:delete(username, query)
	local cache_key = jid_join(username, host, self.store);
	if not query or next(query) == nil then
		archive_item_count_cache:set(cache_key, nil); -- nil because we don't check if the following succeeds
		return datamanager.list_store(username, host, self.store, nil);
	end

	if use_shift and next(query) == "end" and next(query, "end") == nil then
		return self:trim(username, query["end"]);
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
