
local handlers = {};

handlers.accounts = {
	get = function(self, user)
		local select = self:query("select password from users where username=?", user);
		local row = select and select:fetch();
		if row then return { password = row[1] }; end
	end;
	set = function(self, user, data)
		if data and data.password then
			return self:modify("update users set password=? where username=?", data.password, user)
				or self:modify("insert into users (username, password) values (?, ?)", user, data.password);
		else
			return self:modify("delete from users where username=?", user);
		end
	end;
};
handlers.vcard = {
	get = function(self, user)
		local select = self:query("select vcard from vcard where username=?", user);
		local row = select and select:fetch();
		if row then return parse_xml(row[1]); end
	end;
	set = function(self, user, data)
		if data then
			data = unparse_xml(data);
			return self:modify("update vcard set vcard=? where username=?", data, user)
				or self:modify("insert into vcard (username, vcard) values (?, ?)", user, data);
		else
			return self:modify("delete from vcard where username=?", user);
		end
	end;
};
handlers.private = {
	get = function(self, user)
		local select = self:query("select namespace,data from private_storage where username=?", user);
		if select then
			local data = {};
			for row in select:rows() do
				data[row[1]] = parse_xml(row[2]);
			end
			return data;
		end
	end;
	set = function(self, user, data)
		if data then
			self:modify("delete from private_storage where username=?", user);
			for namespace,text in pairs(data) do
				self:modify("insert into private_storage (username, namespace, data) values (?, ?, ?)", user, namespace, unparse_xml(text));
			end
			return true;
		else
			return self:modify("delete from private_storage where username=?", user);
		end
	end;
	-- TODO map_set, map_get
};
local subscription_map = { N = "none", B = "both", F = "from", T = "to" };
local subscription_map_reverse = { none = "N", both = "B", from = "F", to = "T" };
handlers.roster = {
	get = function(self, user)
		local select = self:query("select jid,nick,subscription,ask,server,subscribe,type from rosterusers where username=?", user);
		if select then
			local roster = { pending = {} };
			for row in select:rows() do
				local jid,nick,subscription,ask,server,subscribe,typ = unpack(row);
				local item = { groups = {} };
				if nick == "" then nick = nil; end
				item.nick = nick;
				item.subscription = subscription_map[subscription];
				if ask == "N" then ask = nil;
				elseif ask == "O" then ask = "subscribe"
				elseif ask == "I" then roster.pending[jid] = true; ask = nil;
				elseif ask == "B" then roster.pending[jid] = true; ask = "subscribe";
				else module:log("debug", "bad roster_item.ask: %s", ask); ask = nil; end
				item.ask = ask;
				roster[jid] = item;
			end
			
			select = self:query("select jid,grp from rostergroups where username=?", user);
			if select then
				for row in select:rows() do
					local jid,grp = unpack(rows);
					if roster[jid] then roster[jid].groups[grp] = true; end
				end
			end
			select = self:query("select version from roster_version where username=?", user);
			local row = select and select:fetch();
			if row then
				roster[false] = { version = row[1]; };
			end
			return roster;
		end
	end;
	set = function(self, user, data)
		if data and next(data) ~= nil then
			self:modify("delete from rosterusers where username=?", user);
			self:modify("delete from rostergroups where username=?", user);
			self:modify("delete from roster_version where username=?", user);
			local done = {};
			local pending = data.pending or {};
			for jid,item in pairs(data) do
				if jid and jid ~= "pending" then
					local subscription = subscription_map_reverse[item.subscription];
					local ask;
					if pending[jid] then
						if item.ask then ask = "B"; else ask = "I"; end
					else
						if item.ask then ask = "O"; else ask = "N"; end
					end
					local r = self:modify("insert into rosterusers (username,jid,nick,subscription,ask,askmessage,server,subscribe) values (?, ?, ?, ?, ?, '', '', '')", user, jid, item.nick or "", subscription, ask);
					if not r then module:log("debug", "--- :( %s", tostring(r)); end
					done[jid] = true;
					for group in pairs(item.groups) do
						self:modify("insert into rostergroups (username,jid,grp) values (?, ?, ?)", user, jid, group);
					end
				end
			end
			for jid in pairs(pending) do
				if not done[jid] then
					self:modify("insert into rosterusers (username,jid,nick,subscription,ask,askmessage,server,subscribe) values (?, ?, ?, ?, ?. ''. ''. '')", user, jid, "", "N", "I");
				end
			end
			local version = data[false] and data[false].version;
			if version then
				self:modify("insert into roster_version (username,version) values (?, ?)", user, version);
			end
			return true;
		else
			self:modify("delete from rosterusers where username=?", user);
			self:modify("delete from rostergroups where username=?", user);
			self:modify("delete from roster_version where username=?", user);
		end
	end;
};

-----------------------------
local driver = {};
driver.__index = driver;

function driver:prepare(sql)
	module:log("debug", "query: %s", sql);
	local err;
	if not self.sqlcache then self.sqlcache = {}; end
	local r = self.sqlcache[sql];
	if r then return r; end
	r, err = self.database:prepare(sql);
	if not r then error("Unable to prepare SQL statement: "..err); end
	self.sqlcache[sql] = r;
	return r;
end

function driver:query(sql, ...)
	local stmt = self:prepare(sql);
	if stmt:execute(...) then return stmt; end
end
function driver:modify(sql, ...)
	local stmt = self:query(sql, ...);
	if stmt and stmt:affected() > 0 then return stmt; end
end

function driver:open(host, datastore, typ)
	local cache_key = host.." "..datastore;
	if self.ds_cache[cache_key] then return self.ds_cache[cache_key]; end
	local instance = setmetatable({}, self);
	instance.host = host;
	instance.datastore = datastore;
	local handler = handlers[datastore];
	if not handler then return nil; end
	for key,val in pairs(handler) do
		instance[key] = val;
	end
	if instance.init then instance:init(); end
	self.ds_cache[cache_key] = instance;
	return instance;
end

-----------------------------
local _M = {};

function _M.new(dbtype, dbname, ...)
	local instance = setmetatable({}, driver);
	instance.__index = instance;
	instance.database = get_database(dbtype, dbname, ...);
	instance.ds_cache = {};
	return instance;
end

return _M;
