local serialize = require "util.serialization".serialize;
local envload = require "util.envload".envload;
local st = require "util.stanza";
local is_stanza = st.is_stanza or function (s) return getmetatable(s) == st.stanza_mt end

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

local keyval_store = {};
keyval_store.__index = keyval_store;

function keyval_store:get(username)
	return (self.store[username or NULL] or NULL)();
end

function keyval_store:set(username, data)
	if data ~= nil then
		data = envload("return "..serialize(data), "@data", {});
	end
	self.store[username or NULL] = data;
	return true;
end

keyval_store.purge = _purge_store;

local archive_store = {};
archive_store.__index = archive_store;

function archive_store:append(username, key, value, when, with)
	if type(when) ~= "number" then
		when, with, value = value, when, with;
	end
	if is_stanza(value) then
		value = st.preserialize(value);
		value = envload("return xml"..serialize(value), "@stanza", { xml = st.deserialize })
	else
		value = envload("return "..serialize(value), "@data", {});
	end
	local a = self.store[username or NULL];
	if not a then
		a = {};
		self.store[username or NULL] = a;
	end
	local i = #a+1;
	local v = { key = key, when = when, with = with, value = value };
	if not key then
		key = tostring(a):match"%x+$"..tostring(v):match"%x+$";
		v.key = key;
	end
	if a[key] then
		table.remove(a, a[key]);
	end
	a[i] = v;
	a[key] = i;
	return key;
end

local function archive_iter (a, start, stop, step, limit, when_start, when_end, match_with)
	local item, when, with;
	local count = 0;
	coroutine.yield(true); -- Ready
	for i = start, stop, step do
		item = a[i];
		when, with = item.when, item.with;
		if when >= when_start and when_end >= when and (not match_with or match_with == with) then
			coroutine.yield(item.key, item.value(), when, with);
			count = count + 1;
			if limit and count >= limit then return end
		end
	end
end

function archive_store:find(username, query)
	local a = self.store[username or NULL] or {};
	local start, stop, step = 1, #a, 1;
	local qstart, qend, qwith = -math.huge, math.huge;
	local limit;
	if query then
		module:log("debug", "query included")
		if query.reverse then
			start, stop, step = stop, start, -1;
			if query.before then
				start = a[query.before];
			end
		elseif query.after then
			start = a[query.after];
		end
		limit = query.limit;
		qstart = query.start or qstart;
		qend = query["end"] or qend;
		qwith = query.with;
	end
	if not start then return nil, "invalid-key"; end
	local iter = coroutine.wrap(archive_iter);
	iter(a, start, stop, step, limit, qstart, qend, qwith);
	return iter;
end

function archive_store:delete(username, query)
	if not query or next(query) == nil then
		self.store[username or NULL] = nil;
		return true;
	end
	local old = self.store[username or NULL];
	if not old then return true; end
	local qstart = query.start or -math.huge;
	local qend = query["end"] or math.huge;
	local qwith = query.with;
	local new = {};
	self.store[username or NULL] = new;
	local t;
	for i = 1, #old do
		i = old[i];
		t = i.when;
		if not(qstart >= t and qend <= t and (not qwith or i.with == qwith)) then
			self:append(username, i.key, i.value(), t, i.with);
		end
	end
	if #new == 0 then
		self.store[username or NULL] = nil;
	end
	return true;
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
