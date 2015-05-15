
local ipairs, pairs = ipairs, pairs;
local setmetatable = setmetatable;
local tostring = tostring;
local next = next;
local t_remove = table.remove;
local os_remove = os.remove;
local io_open = io.open;

local paths = require"util.paths";
local st = require "util.stanza";
local parse_xml_real = require "util.xml".parse;

local function getXml(user, host)
	local jid = user.."@"..host;
	local path = paths.join(prosody.paths.data, jid..".xml");
	local f = io_open(path);
	if not f then return; end
	local s = f:read("*a");
	f:close();
	return parse_xml_real(s);
end
local function setXml(user, host, xml)
	local jid = user.."@"..host;
	local path = paths.join(prosody.paths.data, jid..".xml");
	local f, err = io_open(path, "w");
	if not f then return f, err; end
	if xml then
		local s = tostring(xml);
		f:write(s);
		f:close();
		return true;
	else
		f:close();
		return os_remove(path);
	end
end
local function getUserElement(xml)
	if xml and xml.name == "server-data" then
		local host = xml.tags[1];
		if host and host.name == "host" then
			local user = host.tags[1];
			if user and user.name == "user" then
				return user;
			end
		end
	end
end
local function createOuterXml(user, host)
	return st.stanza("server-data", {xmlns='urn:xmpp:pie:0'})
		:tag("host", {jid=host})
			:tag("user", {name = user});
end
local function removeFromArray(array, value)
	for i,item in ipairs(array) do
		if item == value then
			t_remove(array, i);
			return;
		end
	end
end
local function removeStanzaChild(s, child)
	removeFromArray(s.tags, child);
	removeFromArray(s, child);
end

local handlers = {};

-- In order to support mod_auth_internal_hashed
local extended = "http://prosody.im/protocol/extended-xep0227\1";

handlers.accounts = {
	get = function(self, user)
		local user = getUserElement(getXml(user, self.host));
		if user and user.attr.password then
			return { password = user.attr.password };
		elseif user then
			local data = {};
			for k, v in pairs(user.attr) do
				if k:sub(1, #extended) == extended then
					data[k:sub(#extended+1)] = v;
				end
			end
			return data;
		end
	end;
	set = function(self, user, data)
		if data then
			local xml = getXml(user, self.host);
			if not xml then xml = createOuterXml(user, self.host); end
			local usere = getUserElement(xml);
			for k, v in pairs(data) do
				if k == "password" then
					usere.attr.password = v;
				else
					usere.attr[extended..k] = v;
				end
			end
			return setXml(user, self.host, xml);
		else
			return setXml(user, self.host, nil);
		end
	end;
};
handlers.vcard = {
	get = function(self, user)
		local user = getUserElement(getXml(user, self.host));
		if user then
			local vcard = user:get_child("vCard", 'vcard-temp');
			if vcard then
				return st.preserialize(vcard);
			end
		end
	end;
	set = function(self, user, data)
		local xml = getXml(user, self.host);
		local usere = xml and getUserElement(xml);
		if usere then
			local vcard = usere:get_child("vCard", 'vcard-temp');
			if vcard then
				removeStanzaChild(usere, vcard);
			elseif not data then
				return true;
			end
			if data then
				vcard = st.deserialize(data);
				usere:add_child(vcard);
			end
			return setXml(user, self.host, xml);
		end
		return true;
	end;
};
handlers.private = {
	get = function(self, user)
		local user = getUserElement(getXml(user, self.host));
		if user then
			local private = user:get_child("query", "jabber:iq:private");
			if private then
				local r = {};
				for _, tag in ipairs(private.tags) do
					r[tag.name..":"..tag.attr.xmlns] = st.preserialize(tag);
				end
				return r;
			end
		end
	end;
	set = function(self, user, data)
		local xml = getXml(user, self.host);
		local usere = xml and getUserElement(xml);
		if usere then
			local private = usere:get_child("query", 'jabber:iq:private');
			if private then removeStanzaChild(usere, private); end
			if data and next(data) ~= nil then
				private = st.stanza("query", {xmlns='jabber:iq:private'});
				for _,tag in pairs(data) do
					private:add_child(st.deserialize(tag));
				end
				usere:add_child(private);
			end
			return setXml(user, self.host, xml);
		end
		return true;
	end;
};

-----------------------------
local driver = {};

function driver:open(datastore, typ)
	local handler = handlers[datastore];
	if not handler then return nil, "unsupported-datastore"; end
	local instance = setmetatable({ host = module.host; datastore = datastore; }, { __index = handler });
	if instance.init then instance:init(); end
	return instance;
end

module:provides("storage", driver);
