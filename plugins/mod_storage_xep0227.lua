
local ipairs, pairs = ipairs, pairs;
local setmetatable = setmetatable;
local tostring = tostring;
local next, unpack = next, table.unpack or unpack; --luacheck: ignore 113/unpack
local os_remove = os.remove;
local io_open = io.open;
local jid_bare = require "util.jid".bare;
local jid_prep = require "util.jid".prep;

local array = require "util.array";
local base64 = require "util.encodings".base64;
local dt = require "util.datetime";
local hex = require "util.hex";
local it = require "util.iterators";
local paths = require"util.paths";
local set = require "util.set";
local st = require "util.stanza";
local parse_xml_real = require "util.xml".parse;

local lfs = require "lfs";

local function default_get_user_xml(self, user, host)
	local jid = user.."@"..host;
	local path = paths.join(prosody.paths.data, jid..".xml");
	local f, err = io_open(path);
	if not f then
		module:log("debug", "Unable to load XML file for <%s>: %s", jid, err);
		return;
	end
	module:log("debug", "Loaded %s", path);
	local s = f:read("*a");
	f:close();
	return parse_xml_real(s);
end
local function default_set_user_xml(user, host, xml)
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
	module:log("warn", "Unable to find user element");
end
local function createOuterXml(user, host)
	return st.stanza("server-data", {xmlns='urn:xmpp:pie:0'})
		:tag("host", {jid=host})
			:tag("user", {name = user});
end

local function hex_to_base64(s)
	return base64.encode(hex.from(s));
end

local function base64_to_hex(s)
	return base64.encode(hex.from(s));
end

local handlers = {};

-- In order to support custom account properties
local extended = "http://prosody.im/protocol/extended-xep0227\1";

local scram_hash_name = module:get_option_string("password_hash", "SHA-1");
local scram_properties = set.new({ "server_key", "stored_key", "iteration_count", "salt" });

handlers.accounts = {
	get = function(self, user)
		user = getUserElement(self:_get_user_xml(user, self.host));
		local scram_credentials = user and user:get_child_with_attr(
			"scram-credentials", "urn:xmpp:pie:0#scram",
			"mechanism", "SCRAM-"..scram_hash_name
		);
		if scram_credentials then
			return {
				iteration_count = tonumber(scram_credentials:get_child_text("iter-count"));
				server_key = base64_to_hex(scram_credentials:get_child_text("server-key"));
				stored_key = base64_to_hex(scram_credentials:get_child_text("stored-key"));
				salt = base64.decode(scram_credentials:get_child_text("salt"));
			};
		elseif user and user.attr.password then
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
		if not data then
			return self:_set_user_xml(user, self.host, nil);
		end

		local xml = self:_get_user_xml(user, self.host);
		if not xml then xml = createOuterXml(user, self.host); end
		local usere = getUserElement(xml);

		local account_properties = set.new(it.to_array(it.keys(data)));

		-- Include SCRAM credentials if known
		if account_properties:contains_set(scram_properties) then
			local scram_el = st.stanza("scram-credentials", { xmlns = "urn:xmpp:pie:0#scram", mechanism = "SCRAM-"..scram_hash_name })
				:text_tag("server-key", hex_to_base64(data.server_key))
				:text_tag("stored-key", hex_to_base64(data.stored_key))
				:text_tag("iter-count", ("%d"):format(data.iteration_count))
				:text_tag("salt", base64.encode(data.salt));
			usere:add_child(scram_el);
			account_properties:exclude(scram_properties);
		end

		-- Include the password if present
		if account_properties:contains("password") then
			usere.attr.password = data.password;
			account_properties:remove("password");
		end

		-- Preserve remaining properties as namespaced attributes
		for property in account_properties do
			usere.attr[extended..property] = data[property];
		end

		return self:_set_user_xml(user, self.host, xml);
	end;
};
handlers.vcard = {
	get = function(self, user)
		user = getUserElement(self:_get_user_xml(user, self.host));
		if user then
			local vcard = user:get_child("vCard", 'vcard-temp');
			if vcard then
				return st.preserialize(vcard);
			end
		end
	end;
	set = function(self, user, data)
		local xml = self:_get_user_xml(user, self.host);
		local usere = xml and getUserElement(xml);
		if usere then
			usere:remove_children("vCard", "vcard-temp");
			if not data then
				-- No data to set, old one deleted, success
				return true;
			end
			local vcard = st.deserialize(data);
			usere:add_child(vcard);
			return self:_set_user_xml(user, self.host, xml);
		end
		return true;
	end;
};
handlers.private = {
	get = function(self, user)
		user = getUserElement(self:_get_user_xml(user, self.host));
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
		local xml = self:_get_user_xml(user, self.host);
		local usere = xml and getUserElement(xml);
		if usere then
			usere:remove_children("query", "jabber:iq:private");
			if data and next(data) ~= nil then
				local private = st.stanza("query", {xmlns='jabber:iq:private'});
				for _,tag in pairs(data) do
					private:add_child(st.deserialize(tag));
				end
				usere:add_child(private);
			end
			return self:_set_user_xml(user, self.host, xml);
		end
		return true;
	end;
};

handlers.roster = {
	get = function(self, user)
		user = getUserElement(self:_get_user_xml(user, self.host));
		if user then
			local roster = user:get_child("query", "jabber:iq:roster");
			if roster then
				local r = {
					[false] = {
						version = roster.attr.version;
						pending = {};
					}
				};
				for item in roster:childtags("item") do
					r[item.attr.jid] = {
						jid = item.attr.jid,
						subscription = item.attr.subscription,
						ask = item.attr.ask,
						name = item.attr.name,
						groups = {};
					};
					for group in item:childtags("group") do
						r[item.attr.jid].groups[group:get_text()] = true;
					end
					for pending in user:childtags("presence", "jabber:client") do
						r[false].pending[pending.attr.from] = true;
					end
				end
				return r;
			end
		end
	end;
	set = function(self, user, data)
		local xml = self:_get_user_xml(user, self.host);
		local usere = xml and getUserElement(xml);
		if usere then
			usere:remove_children("query", "jabber:iq:roster");
			usere:maptags(function (tag)
				if tag.attr.xmlns == "jabber:client" and tag.name == "presence" and tag.attr.type == "subscribe" then
					return nil;
				end
				return tag;
			end);
			if data and next(data) ~= nil then
				local roster = st.stanza("query", {xmlns='jabber:iq:roster'});
				usere:add_child(roster);
				for jid, item in pairs(data) do
					if jid then
						roster:tag("item", {
							jid = jid,
							subscription = item.subscription,
							ask = item.ask,
							name = item.name,
						});
						for group in pairs(item.groups) do
							roster:tag("group"):text(group):up();
						end
						roster:up(); -- move out from item
					else
						roster.attr.version = item.version;
						for pending_jid in pairs(item.pending) do
							usere:add_child(st.presence({ from = pending_jid, type = "subscribe" }));
						end
					end
				end
			end
			return self:_set_user_xml(user, self.host, xml);
		end
		return true;
	end;
};

-- PEP node configuration/etc. (not items)
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";
local lib_pubsub = module:require "pubsub";
handlers.pep = {
	get = function (self, user)
		local xml = self:_get_user_xml(user, self.host);
		local user_el = xml and getUserElement(xml);
		if not user_el then
			return nil;
		end
		local nodes = {
			--[[
			[node_name] = {
				name = node_name;
				config = {};
				affiliations = {};
				subscribers = {};
			};
			]]
		};
		local owner_el = user_el:get_child("pubsub", xmlns_pubsub_owner);
		for node_el in owner_el:childtags() do
			local node_name = node_el.attr.node;
			local node = nodes[node_name];
			if not node then
				node = {
					name = node_name;
					config = {};
					affiliations = {};
					subscribers = {};
				};
				nodes[node_name] = node;
			end
			if node_el.name == "configure" then
				local form = node_el:get_child("x", "jabber:x:data");
				if form then
					node.config = lib_pubsub.node_config_form:data(form);
				end
			elseif node_el.name == "affiliations" then
				for affiliation_el in node_el:childtags("affiliation") do
					local aff_jid = jid_prep(affiliation_el.attr.jid);
					local aff_value = affiliation_el.attr.affiliation;
					if aff_jid and aff_value then
						node.affiliations[aff_jid] = aff_value;
					end
				end
			elseif node_el.name == "subscriptions" then
				for subscription_el in node_el:childtags("subscription") do
					local sub_jid = jid_prep(subscription_el.attr.jid);
					local sub_state = subscription_el.attr.subscription;
					if sub_jid and sub_state == "subscribed" then
						local options;
						local subscription_options_el = subscription_el:get_child("options");
						if subscription_options_el then
							local options_form = subscription_options_el:get_child("x", "jabber:x:data");
							if options_form then
								options = lib_pubsub.subscription_options_form:data(options_form);
							end
						end
						node.subscribers[sub_jid] = options or true;
					end
				end
			else
				module:log("warn", "Ignoring unknown pubsub element: %s", node_el.name);
			end
		end
		return nodes;
	end;
	set = function(self, user, data)
		local xml = self:_get_user_xml(user, self.host);
		local user_el = xml and getUserElement(xml);
		if not user_el then
			return true;
		end
		-- Remove existing data, if any
		user_el:remove_children("pubsub", xmlns_pubsub_owner);

		-- Generate new data
		local owner_el = st.stanza("pubsub", { xmlns = xmlns_pubsub_owner });

		for node_name, node_data in pairs(data) do
			local configure_el = st.stanza("configure", { node = node_name })
				:add_child(lib_pubsub.node_config_form:form(node_data.config, "submit"));
			owner_el:add_child(configure_el);
			if node_data.affiliations and next(node_data.affiliations) ~= nil then
				local affiliations_el = st.stanza("affiliations", { node = node_name });
				for aff_jid, aff_value in pairs(node_data.affiliations) do
					affiliations_el:tag("affiliation", { jid = aff_jid, affiliation = aff_value }):up();
				end
				owner_el:add_child(affiliations_el);
			end
			if node_data.subscribers and next(node_data.subscribers) ~= nil then
				local subscriptions_el = st.stanza("subscriptions", { node = node_name });
				for sub_jid, sub_data in pairs(node_data.subscribers) do
					local sub_el = st.stanza("subscription", { jid = sub_jid, subscribed = "subscribed" });
					if sub_data ~= true then
						local options_form = lib_pubsub.subscription_options_form:form(sub_data, "submit");
						sub_el:tag("options"):add_child(options_form):up();
					end
					subscriptions_el:add_child(sub_el);
				end
				owner_el:add_child(subscriptions_el);
			end
		end

		user_el:add_child(owner_el);

		return self:_set_user_xml(user, self.host, xml);
	end;
};

-- PEP items
local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
handlers.pep_ = {
	_stores = function (self, xml) --luacheck: ignore 212/self
		local store_names = set.new();

		local user_el = xml and getUserElement(xml);
		if not user_el then
			return store_names;
		end

		-- Locate existing pubsub element, if any
		local pubsub_el = user_el:get_child("pubsub", xmlns_pubsub);
		if not pubsub_el then
			return store_names;
		end

		-- Find node items element, if any
		for items_el in pubsub_el:childtags("items") do
			store_names:add("pep_"..items_el.attr.node);
		end
		return store_names;
	end;
	find = function (self, user, query)
		-- query keys: limit, reverse, key (id)

		local xml = self:_get_user_xml(user, self.host);
		local user_el = xml and getUserElement(xml);
		if not user_el then
			return nil, "no 227 user element found";
		end

		local node_name = self.datastore:match("^pep_(.+)$");

		-- Locate existing pubsub element, if any
		local pubsub_el = user_el:get_child("pubsub", xmlns_pubsub);
		if not pubsub_el then
			return nil;
		end

		-- Find node items element, if any
		local node_items_el;
		for items_el in pubsub_el:childtags("items") do
			if items_el.attr.node == node_name then
				node_items_el = items_el;
				break;
			end
		end

		if not node_items_el then
			return nil;
		end

		local user_jid = user.."@"..self.host;

		local results = {};
		for item_el in node_items_el:childtags("item") do
			if query and query.key then
				if item_el.attr.id == query.key then
					table.insert(results, { item_el.attr.id, item_el.tags[1], 0, user_jid });
					break;
				end
			else
				table.insert(results, { item_el.attr.id, item_el.tags[1], 0, user_jid });
			end
			if query and query.limit and #results >= query.limit then
				break;
			end
		end
		if query and query.reverse then
			return array.reverse(results);
		end
		local i = 0;
		return function ()
			i = i + 1;
			local v = results[i];
			if v == nil then return nil; end
			return unpack(v, 1, 4);
		end;
	end;
	append = function (self, user, key, payload, when, with) --luacheck: ignore 212/when 212/with 212/key
		local xml = self:_get_user_xml(user, self.host);
		local user_el = xml and getUserElement(xml);
		if not user_el then
			return true;
		end

		local node_name = self.datastore:match("^pep_(.+)$");

		-- Locate existing pubsub element, if any
		local pubsub_el = user_el:get_child("pubsub", xmlns_pubsub);
		if not pubsub_el then
			pubsub_el = st.stanza("pubsub", { xmlns = xmlns_pubsub });
			user_el:add_child(pubsub_el);
		end

		-- Find node items element, if any
		local node_items_el;
		for items_el in pubsub_el:childtags("items") do
			if items_el.attr.node == node_name then
				node_items_el = items_el;
				break;
			end
		end

		if not node_items_el then
			-- Doesn't exist yet, create one
			node_items_el = st.stanza("items", { node = node_name });
			pubsub_el:add_child(node_items_el);
		end

		-- Append item to pubsub_el
		local item_el = st.stanza("item", { id = key })
			:add_child(payload);
		node_items_el:add_child(item_el);

		return self:_set_user_xml(user, self.host, xml);
	end;
	delete = function (self, user, query)
		-- query keys: limit, reverse, key (id)

		local xml = self:_get_user_xml(user, self.host);
		local user_el = xml and getUserElement(xml);
		if not user_el then
			return nil, "no 227 user element found";
		end

		local node_name = self.datastore:match("^pep_(.+)$");

		-- Locate existing pubsub element, if any
		local pubsub_el = user_el:get_child("pubsub", xmlns_pubsub);
		if not pubsub_el then
			return nil;
		end

		-- Find node items element, if any
		local node_items_el;
		for items_el in pubsub_el:childtags("items") do
			if items_el.attr.node == node_name then
				node_items_el = items_el;
				break;
			end
		end

		if not node_items_el then
			return nil;
		end

		local results = array();
		for item_el in pubsub_el:childtags("item") do
			if query and query.key then
				if item_el.attr.id == query.key then
					table.insert(results, item_el);
					break;
				end
			else
				table.insert(results, item_el);
			end
			if query and query.limit and #results >= query.limit then
				break;
			end
		end
		if query and query.truncate then
			results:sub(-query.truncate);
		end

		-- Actually remove the matching items
		local delete_keys = set.new(results:map(function (item) return item.attr.id; end));
		pubsub_el:maptags(function (item_el)
			if delete_keys:contains(item_el.attr.id) then
				return nil;
			end
			return item_el;
		end);
		return self:_set_user_xml(user, self.host, xml);
	end;
};

-- MAM archives
local xmlns_pie_mam = "urn:xmpp:pie:0#mam";
handlers.archive = {
	find = function (self, user, query)
		assert(query == nil, "XEP-0313 queries are not supported on XEP-0227 files");

		local xml = self:_get_user_xml(user, self.host);
		local user_el = xml and getUserElement(xml);
		if not user_el then
			return nil, "no 227 user element found";
		end

		-- Locate existing archive element, if any
		local archive_el = user_el:get_child("archive", xmlns_pie_mam);
		if not archive_el then
			return nil;
		end

		local user_jid = user.."@"..self.host;


		local f, s, result_el = archive_el:childtags("result", "urn:xmpp:mam:2");
		return function ()
			result_el = f(s, result_el);
			if not result_el then return nil; end

			local id = result_el.attr.id;
			local item = result_el:find("{urn:xmpp:forward:0}forwarded/{jabber:client}message");
			assert(item, "Invalid stanza in XEP-0227 archive");
			local when = dt.parse(result_el:find("{urn:xmpp:forward:0}forwarded/{urn:xmpp:delay}delay@stamp"));
			local to_bare, from_bare = jid_bare(item.attr.to), jid_bare(item.attr.from);
			local with = to_bare == user_jid and from_bare or to_bare;
			-- id, item, when, with
			return id, item, when, with;
		end;
	end;
	append = function (self, user, key, payload, when, with) --luacheck: ignore 212/when 212/with 212/key
		local xml = self:_get_user_xml(user, self.host);
		local user_el = xml and getUserElement(xml);
		if not user_el then
			return true;
		end

		-- Locate existing archive element, if any
		local archive_el = user_el:get_child("archive", xmlns_pie_mam);
		if not archive_el then
			archive_el = st.stanza("archive", { xmlns = xmlns_pie_mam });
			user_el:add_child(archive_el);
		end

		local item = st.clone(payload);
		item.attr.xmlns = "jabber:client";

		local result_el = st.stanza("result", { xmlns = "urn:xmpp:mam:2", id = key })
			:tag("forwarded", { xmlns = "urn:xmpp:forward:0" })
				:tag("delay", { xmlns = "urn:xmpp:delay", stamp = dt.datetime(when) }):up()
				:add_child(item)
			:up();

		-- Append item to archive_el
		archive_el:add_child(result_el);

		return self:_set_user_xml(user, self.host, xml);
	end;
};

-----------------------------
local driver = {};

local function users(self)
	local file_patt = "^.*@"..(self.host:gsub("%p", "%%%1")).."%.xml$";

	local f, s, filename = lfs.dir(prosody.paths.data);

	return function ()
		filename = f(s, filename);
		while filename and not filename:match(file_patt) do
			filename = f(s, filename);
		end
		if not filename then return nil; end
		return filename:match("^[^@]+");
	end;
end

function driver:open(datastore, typ) -- luacheck: ignore 212/self
	if typ and typ ~= "keyval" and typ ~= "archive" then return nil, "unsupported-store"; end
	local handler = handlers[datastore];
	if not handler and datastore:match("^pep_") then
		handler = handlers.pep_;
	end
	if not handler then return nil, "unsupported-datastore"; end
	local instance = setmetatable({
			host = module.host;
			datastore = datastore;
			users = users;
			_get_user_xml = assert(default_get_user_xml);
			_set_user_xml = default_set_user_xml;
		}, {
			__index = handler;
		}
	);
	if instance.init then instance:init(); end
	return instance;
end

-- Custom API that allows some configuration
function driver:open_xep0227(datastore, typ, options)
	local instance, err = self:open(datastore, typ);
	if not instance then
		return instance, err;
	end
	if options then
		instance._set_user_xml = assert(options.set_user_xml);
		instance._get_user_xml = assert(options.get_user_xml);
	end
	return instance;
end

local function get_store_names(self, path)
	local stores = set.new();
	local f, err = io_open(paths.join(prosody.paths.data, path));
	if not f then
		module:log("warn", "Unable to load XML file for <%s>: %s", "store listing", err);
		return stores;
	end
	module:log("info", "Loaded %s", path);
	local s = f:read("*a");
	f:close();
	local xml = parse_xml_real(s);
	for _, handler_funcs in pairs(handlers) do
		if handler_funcs._stores then
			stores:include(handler_funcs._stores(self, xml));
		end
	end
	return stores;
end

function driver:stores(username)
	local store_dir = prosody.paths.data;

	local mode, err = lfs.attributes(store_dir, "mode");
	if not mode then
		return function() module:log("debug", "Could not iterate over stores in %s: %s", store_dir, err); end
	end

	local file_patt = "^.*@"..(module.host:gsub("%p", "%%%1")).."%.xml$";

	local all_users = username == true;

	local store_names = set.new();

	for filename in lfs.dir(prosody.paths.data) do
		if filename:match(file_patt) then
			if all_users or filename == username.."@"..module.host..".xml" then
				store_names:include(get_store_names(self, filename));
				if not all_users then break; end
			end
		end
	end

	return store_names:items();
end

module:provides("storage", driver);
