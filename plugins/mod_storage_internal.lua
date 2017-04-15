local datamanager = require "core.storagemanager".olddm;
local array = require "util.array";
local datetime = require "util.datetime";
local st = require "util.stanza";
local now = require "util.time".now;
local id = require "util.id".medium;

local host = module.host;

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

function archive:append(username, key, value, when, with)
	key = key or id();
	when = when or now();
	if not st.is_stanza(value) then
		return nil, "unsupported-datatype";
	end
	value = st.preserialize(st.clone(value));
	value.key = key;
	value.when = when;
	value.with = with;
	value.attr.stamp = datetime.datetime(when);
	value.attr.stamp_legacy = datetime.legacy(when);
	local ok, err = datamanager.list_append(username, host, self.store, value);
	if not ok then return ok, err; end
	return key;
end

function archive:find(username, query)
	local items, err = datamanager.list_load(username, host, self.store);
	if not items then return items, err; end
	local count = #items;
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

function archive:delete(username, query)
	if not query or next(query) == nil then
		return datamanager.list_store(username, host, self.store, nil);
	end
	for k in pairs(query) do
		if k ~= "end" then return nil, "unsupported-query-field"; end
	end
	local items, err = datamanager.list_load(username, host, self.store);
	if not items then return items, err; end
	items = array(items);
	items:filter(function (item)
		return item.when > query["end"];
	end);
	local count = #items;
	local ok, err = datamanager.list_store(username, host, self.store, items);
	if not ok then return ok, err; end
	return count;
end

module:provides("storage", driver);
