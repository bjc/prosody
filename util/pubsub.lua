local events = require "prosody.util.events";
local cache = require "prosody.util.cache";

local service_mt = {};

local default_config = {
	max_items = 256;
	itemstore = function (config, _) return cache.new(config["max_items"]) end;
	broadcaster = function () end;
	subscriber_filter = function (subs) return subs end;
	itemcheck = function () return true; end;
	get_affiliation = function () end;
	normalize_jid = function (jid) return jid; end;
	metadata_subset = {};
	capabilities = {
		outcast = {
			create = false;
			publish = false;
			retract = false;
			get_nodes = false;

			subscribe = false;
			unsubscribe = false;
			get_subscription = true;
			get_subscriptions = true;
			get_items = false;

			subscribe_other = false;
			unsubscribe_other = false;
			get_subscription_other = false;
			get_subscriptions_other = false;

			be_subscribed = false;
			be_unsubscribed = true;

			set_affiliation = false;
		};
		none = {
			create = false;
			publish = false;
			retract = false;
			get_nodes = true;

			subscribe = true;
			unsubscribe = true;
			get_subscription = true;
			get_subscriptions = true;
			get_items = false;
			get_metadata = true;

			subscribe_other = false;
			unsubscribe_other = false;
			get_subscription_other = false;
			get_subscriptions_other = false;

			be_subscribed = true;
			be_unsubscribed = true;

			set_affiliation = false;
		};
		member = {
			create = false;
			publish = false;
			retract = false;
			get_nodes = true;

			subscribe = true;
			unsubscribe = true;
			get_subscription = true;
			get_subscriptions = true;
			get_items = true;
			get_metadata = true;

			subscribe_other = false;
			unsubscribe_other = false;
			get_subscription_other = false;
			get_subscriptions_other = false;

			be_subscribed = true;
			be_unsubscribed = true;

			set_affiliation = false;
		};
		publisher = {
			create = false;
			publish = true;
			retract = true;
			get_nodes = true;
			get_configuration = true;

			subscribe = true;
			unsubscribe = true;
			get_subscription = true;
			get_subscriptions = true;
			get_items = true;
			get_metadata = true;

			subscribe_other = false;
			unsubscribe_other = false;
			get_subscription_other = false;
			get_subscriptions_other = false;

			be_subscribed = true;
			be_unsubscribed = true;

			set_affiliation = false;
		};
		owner = {
			create = true;
			publish = true;
			retract = true;
			delete = true;
			get_nodes = true;
			configure = true;
			get_configuration = true;

			subscribe = true;
			unsubscribe = true;
			get_subscription = true;
			get_subscriptions = true;
			get_items = true;
			get_metadata = true;


			subscribe_other = true;
			unsubscribe_other = true;
			get_subscription_other = true;
			get_subscriptions_other = true;

			be_subscribed = true;
			be_unsubscribed = true;

			set_affiliation = true;
		};
	};
};
local default_config_mt = { __index = default_config };

local default_node_config = {
	["persist_items"] = true;
	["max_items"] = 20;
	["access_model"] = "open";
	["publish_model"] = "publishers";
	["send_last_published_item"] = "never";
};
local default_node_config_mt = { __index = default_node_config };

-- Storage helper functions

local function load_node_from_store(service, node_name)
	local node = service.config.nodestore:get(node_name);
	node.config = setmetatable(node.config or {}, {__index=service.node_defaults});
	return node;
end

local function save_node_to_store(service, node)
	return service.config.nodestore:set(node.name, {
		name = node.name;
		config = node.config;
		subscribers = node.subscribers;
		affiliations = node.affiliations;
	});
end

local function delete_node_in_store(service, node_name)
	return service.config.nodestore:set(node_name, nil);
end

-- Create and return a new service object
local function new(config)
	config = config or {};

	local service = setmetatable({
		config = setmetatable(config, default_config_mt);
		node_defaults = setmetatable(config.node_defaults or {}, default_node_config_mt);
		affiliations = {};
		subscriptions = {};
		nodes = {};
		data = {};
		events = events.new();
	}, service_mt);

	-- Load nodes from storage, if we have a store and it supports iterating over stored items
	if config.nodestore and config.nodestore.users then
		for node_name in config.nodestore:users() do
			local node = load_node_from_store(service, node_name);
			service.nodes[node_name] = node;
			if node.config.persist_items then
				service.data[node_name] = config.itemstore(service.nodes[node_name].config, node_name);
			end

			for jid in pairs(service.nodes[node_name].subscribers) do
				local normal_jid = service.config.normalize_jid(jid);
				local subs = service.subscriptions[normal_jid];
				if subs then
					if not subs[jid] then
						subs[jid] = { [node_name] = true };
					else
						subs[jid][node_name] = true;
					end
				else
					service.subscriptions[normal_jid] = { [jid] = { [node_name] = true } };
				end
			end
		end
	end

	return service;
end

--- Service methods

local service = {};
service_mt.__index = service;

function service:jids_equal(jid1, jid2) --> boolean
	local normalize = self.config.normalize_jid;
	return normalize(jid1) == normalize(jid2);
end

function service:may(node, actor, action) --> boolean
	if actor == true then return true; end

	local node_obj = self.nodes[node];
	local node_aff = node_obj and (node_obj.affiliations[actor]
	              or node_obj.affiliations[self.config.normalize_jid(actor)]);
	local service_aff = self.affiliations[actor]
	                 or self.config.get_affiliation(actor, node, action);
	local default_aff = self:get_default_affiliation(node, actor) or "none";

	-- Check if node allows/forbids it
	local node_capabilities = node_obj and node_obj.capabilities;
	if node_capabilities then
		local caps = node_capabilities[node_aff or service_aff or default_aff];
		if caps then
			local can = caps[action];
			if can ~= nil then
				return can;
			end
		end
	end

	-- Check service-wide capabilities instead
	local service_capabilities = self.config.capabilities;
	local caps = service_capabilities[node_aff or service_aff or default_aff];
	if caps then
		local can = caps[action];
		if can ~= nil then
			return can;
		end
	end

	return false;
end

function service:get_default_affiliation(node, actor) --> affiliation
	local node_obj = self.nodes[node];
	local access_model = node_obj and node_obj.config.access_model
		or self.node_defaults.access_model;

	if access_model == "open" then
		return "member";
	elseif access_model == "whitelist" then
		return "outcast";
	end

	if self.config.access_models then
		local check = self.config.access_models[access_model];
		if check then
			local aff = check(actor, node_obj);
			if aff then
				return aff;
			end
		end
	end
end

function service:set_affiliation(node, actor, jid, affiliation) --> ok, err
	-- Access checking
	if not self:may(node, actor, "set_affiliation") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	jid = self.config.normalize_jid(jid);
	local old_affiliation = node_obj.affiliations[jid];
	node_obj.affiliations[jid] = affiliation;

	if self.config.nodestore then
		-- TODO pass the error from storage to caller eg wrapped in an util.error
		local ok, err = save_node_to_store(self, node_obj); -- luacheck: ignore 211/err
		if not ok then
			node_obj.affiliations[jid] = old_affiliation;
			return ok, "internal-server-error";
		end
	end

	local _, jid_sub = self:get_subscription(node, true, jid);
	if not jid_sub and not self:may(node, jid, "be_unsubscribed") then
		local ok, err = self:add_subscription(node, true, jid);
		if not ok then
			return ok, err;
		end
	elseif jid_sub and not self:may(node, jid, "be_subscribed") then
		local ok, err = self:add_subscription(node, true, jid);
		if not ok then
			return ok, err;
		end
	end
	return true;
end

function service:add_subscription(node, actor, jid, options) --> ok, err
	-- Access checking
	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "subscribe";
	else
		cap = "subscribe_other";
	end
	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end
	if not self:may(node, jid, "be_subscribed") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		if not self.config.autocreate_on_subscribe then
			return false, "item-not-found";
		else
			local ok, err = self:create(node, true);
			if not ok then
				return ok, err;
			end
			node_obj = self.nodes[node];
		end
	end
	local old_subscription = node_obj.subscribers[jid];
	node_obj.subscribers[jid] = options or true;
	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid];
	if subs then
		if not subs[jid] then
			subs[jid] = { [node] = true };
		else
			subs[jid][node] = true;
		end
	else
		self.subscriptions[normal_jid] = { [jid] = { [node] = true } };
	end

	if self.config.nodestore then
		-- TODO pass the error from storage to caller eg wrapped in an util.error
		local ok, err = save_node_to_store(self, node_obj); -- luacheck: ignore 211/err
		if not ok then
			node_obj.subscribers[jid] = old_subscription;
			self.subscriptions[normal_jid][jid][node] = old_subscription and true or nil;
			return ok, "internal-server-error";
		end
	end

	self.events.fire_event("subscription-added", { service = self, node = node, jid = jid, normalized_jid = normal_jid, options = options });
	return true;
end

function service:remove_subscription(node, actor, jid) --> ok, err
	-- Access checking
	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "unsubscribe";
	else
		cap = "unsubscribe_other";
	end
	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end
	if not self:may(node, jid, "be_unsubscribed") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	if not node_obj.subscribers[jid] then
		return false, "not-subscribed";
	end
	local old_subscription = node_obj.subscribers[jid];
	node_obj.subscribers[jid] = nil;
	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid];
	if subs then
		local jid_subs = subs[jid];
		if jid_subs then
			jid_subs[node] = nil;
			if next(jid_subs) == nil then
				subs[jid] = nil;
			end
		end
		if next(subs) == nil then
			self.subscriptions[normal_jid] = nil;
		end
	end

	if self.config.nodestore then
		-- TODO pass the error from storage to caller eg wrapped in an util.error
		local ok, err = save_node_to_store(self, node_obj); -- luacheck: ignore 211/err
		if not ok then
			node_obj.subscribers[jid] = old_subscription;
			self.subscriptions[normal_jid][jid][node] = old_subscription and true or nil;
			return ok, "internal-server-error";
		end
	end

	self.events.fire_event("subscription-removed", { service = self, node = node, jid = jid, normalized_jid = normal_jid });
	return true;
end

function service:get_subscription(node, actor, jid) --> (true, subscription) or (false, err)
	-- Access checking
	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "get_subscription";
	else
		cap = "get_subscription_other";
	end
	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	return true, node_obj.subscribers[jid];
end

function service:create(node, actor, options) --> ok, err
	-- Access checking
	if not self:may(node, actor, "create") then
		return false, "forbidden";
	end
	--
	if self.nodes[node] then
		return false, "conflict";
	end

	local config = setmetatable(options or {}, {__index=self.node_defaults});

	if self.config.check_node_config then
		local ok = self.config.check_node_config(node, actor, config);
		if not ok then
			return false, "not-acceptable";
		end
	end

	self.nodes[node] = {
		name = node;
		subscribers = {};
		config = config;
		affiliations = {};
	};

	if self.config.nodestore then
		-- TODO pass the error from storage to caller eg wrapped in an util.error
		local ok, err = save_node_to_store(self, self.nodes[node]); -- luacheck: ignore 211/err
		if not ok then
			self.nodes[node] = nil;
			return ok, "internal-server-error";
		end
	end

	if config.persist_items then
		self.data[node] = self.config.itemstore(self.nodes[node].config, node);
	end

	self.events.fire_event("node-created", { service = self, node = node, actor = actor });
	if actor ~= true then
		local ok, err = self:set_affiliation(node, true, actor, "owner");
		if not ok then
			self.nodes[node] = nil;
			self.data[node] = nil;
			return ok, err;
		end
	end

	return true;
end

function service:delete(node, actor) --> ok, err
	-- Access checking
	if not self:may(node, actor, "delete") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	self.nodes[node] = nil;
	if self.data[node] and self.data[node].clear then
		self.data[node]:clear();
	end
	self.data[node] = nil;

	if self.config.nodestore then
		local ok, err = delete_node_in_store(self, node);
		if not ok then
			self.nodes[node] = nil;
			return ok, err;
		end
	end

	self.events.fire_event("node-deleted", { service = self, node = node, actor = actor });
	self:broadcast("delete", node, node_obj.subscribers, nil, actor, node_obj);
	return true;
end

-- Used to check that the config of a node is as expected (i.e. 'publish-options')
local function check_preconditions(node_config, required_config)
	if not (node_config and required_config) then
		return false;
	end
	for config_field, value in pairs(required_config) do
		if node_config[config_field] ~= value then
			return false, config_field;
		end
	end
	return true;
end

function service:publish(node, actor, id, item, requested_config) --> ok, err
	-- Access checking
	local may_publish = false;

	if self:may(node, actor, "publish") then
		may_publish = true;
	else
		local node_obj = self.nodes[node];
		local publish_model = node_obj and node_obj.config.publish_model;
		if publish_model == "open"
		or (publish_model == "subscribers" and node_obj.subscribers[actor]) then
			may_publish = true;
		end
	end
	if not may_publish then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		if not self.config.autocreate_on_publish then
			return false, "item-not-found";
		end
		local ok, err = self:create(node, true, requested_config);
		if not ok then
			return ok, err;
		end
		node_obj = self.nodes[node];
	elseif requested_config and not requested_config._defaults_only then
		-- Check that node has the requested config before we publish
		local ok, field = check_preconditions(node_obj.config, requested_config);
		if not ok then
			return false, "precondition-not-met", { field = field };
		end
	end
	if not self.config.itemcheck(item) then
		return nil, "invalid-item";
	end
	if node_obj.config.persist_items then
		if not self.data[node] then
			self.data[node] = self.config.itemstore(self.nodes[node].config, node);
		end
		local ok = self.data[node]:set(id, item);
		if not ok then
			return nil, "internal-server-error";
		end
		if type(ok) == "string" then id = ok; end
	end
	local event_data = { service = self, node = node, actor = actor, id = id, item = item };
	self.events.fire_event("item-published/"..node, event_data);
	self.events.fire_event("item-published", event_data);
	self:broadcast("items", node, node_obj.subscribers, item, actor, node_obj);
	return true;
end

function service:broadcast(event, node, subscribers, item, actor, node_obj)
	subscribers = self.config.subscriber_filter(subscribers, node, event);
	return self.config.broadcaster(event, node, subscribers, item, actor, node_obj, self);
end

function service:retract(node, actor, id, retract) --> ok, err
	-- Access checking
	if not self:may(node, actor, "retract") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	if self.data[node] then
		if not self.data[node]:get(id) then
			return false, "item-not-found";
		end
		local ok = self.data[node]:set(id, nil);
		if not ok then
			return nil, "internal-server-error";
		end
	end
	self.events.fire_event("item-retracted", { service = self, node = node, actor = actor, id = id });
	if retract then
		self:broadcast("retract", node, node_obj.subscribers, retract, actor, node_obj);
	end
	return true
end

function service:purge(node, actor, notify) --> ok, err
	-- Access checking
	if not self:may(node, actor, "retract") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	if self.data[node] then
		if self.data[node].clear then
			self.data[node]:clear()
		else
			self.data[node] = self.config.itemstore(self.nodes[node].config, node);
		end
	end
	self.events.fire_event("node-purged", { service = self, node = node, actor = actor });
	if notify then
		self:broadcast("purge", node, node_obj.subscribers, nil, actor, node_obj);
	end
	return true
end

function service:get_items(node, actor, ids, resultspec) --> (true, { id, [id] = node }) or (false, err)
	-- Access checking
	if not self:may(node, actor, "get_items") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	if not self.data[node] then
		-- Disabled rather than unsupported, but close enough.
		return false, "persistent-items-unsupported";
	end
	if type(ids) == "string" then -- COMPAT see #1305
		ids = { ids };
	end
	local data = {};
	local limit = resultspec and resultspec.max;
	if ids then
		for _, key in ipairs(ids) do
			local value = self.data[node]:get(key);
			if value then
				data[#data+1] = key;
				data[key] = value;
				-- Limits and ids seem like a problematic combination.
				if limit and #data >= limit then break end
			end
		end
	else
		for key, value in self.data[node]:items() do
			data[#data+1] = key;
			data[key] = value;
			if limit and #data >= limit then break
			end
		end
	end
	return true, data;
end

function service:get_last_item(node, actor) --> (true, id, node) or (false, err)
	-- Access checking
	if not self:may(node, actor, "get_items") then
		return false, "forbidden";
	end
	--

	-- Check node exists
	if not self.nodes[node] then
		return false, "item-not-found";
	end

	if not self.data[node] then
		-- FIXME Should this be a success or failure?
		return true, nil;
	end

	-- Returns success, id, item
	return true, self.data[node]:head();
end

function service:get_nodes(actor) --> (true, map) or (false, err)
	-- Access checking
	if not self:may(nil, actor, "get_nodes") then
		return false, "forbidden";
	end
	--
	return true, self.nodes;
end

local function flatten_subscriptions(ret, serv, subs, node, node_obj)
	for subscribed_jid, subscribed_nodes in pairs(subs) do
		if node then -- Return only subscriptions to this node
			if subscribed_nodes[node] then
				ret[#ret+1] = {
					node = node;
					jid = subscribed_jid;
					subscription = node_obj.subscribers[subscribed_jid];
				};
			end
		else -- Return subscriptions to all nodes
			local nodes = serv.nodes;
			for subscribed_node in pairs(subscribed_nodes) do
				ret[#ret+1] = {
					node = subscribed_node;
					jid = subscribed_jid;
					subscription = nodes[subscribed_node].subscribers[subscribed_jid];
				};
			end
		end
	end
end

function service:get_subscriptions(node, actor, jid) --> (true, array) or (false, err)
	-- Access checking
	local cap;
	if actor == true or jid == actor or self:jids_equal(actor, jid) then
		cap = "get_subscriptions";
	else
		cap = "get_subscriptions_other";
	end
	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end
	--
	local node_obj;
	if node then
		node_obj = self.nodes[node];
		if not node_obj then
			return false, "item-not-found";
		end
	end
	local ret = {};
	if jid == nil then
		for _, subs in pairs(self.subscriptions) do
			flatten_subscriptions(ret, self, subs, node, node_obj)
		end
		return true, ret;
	end
	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid];
	-- We return the subscription object from the node to save
	-- a get_subscription() call for each node.
	if subs then
		flatten_subscriptions(ret, self, subs, node, node_obj)
	end
	return true, ret;
end

-- Access models only affect 'none' affiliation caps, service/default access level...
function service:set_node_capabilities(node, actor, capabilities) --> ok, err
	-- Access checking
	if not self:may(node, actor, "configure") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	node_obj.capabilities = capabilities;
	return true;
end

function service:set_node_config(node, actor, new_config) --> ok, err
	if not self:may(node, actor, "configure") then
		return false, "forbidden";
	end

	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end

	setmetatable(new_config, {__index=self.node_defaults})

	if self.config.check_node_config then
		local ok = self.config.check_node_config(node, actor, new_config);
		if not ok then
			return false, "not-acceptable";
		end
	end

	local old_config = node_obj.config;
	node_obj.config = new_config;

	if self.config.nodestore then
		-- TODO pass the error from storage to caller eg wrapped in an util.error
		local ok, err = save_node_to_store(self, node_obj); -- luacheck: ignore 211/err
		if not ok then
			node_obj.config = old_config;
			return ok, "internal-server-error";
		end
	end

	if old_config["access_model"] ~= node_obj.config["access_model"] then
		for subscriber in pairs(node_obj.subscribers) do
			if not self:may(node, subscriber, "be_subscribed") then
				local ok, err = self:remove_subscription(node, true, subscriber);
				if not ok then
					node_obj.config = old_config;
					return ok, err;
				end
			end
		end
	end

	if old_config["persist_items"] ~= node_obj.config["persist_items"] then
		if node_obj.config["persist_items"] then
			self.data[node] = self.config.itemstore(self.nodes[node].config, node);
		elseif self.data[node] then
			if self.data[node].clear then
				self.data[node]:clear()
			end
			self.data[node] = nil;
		end
	elseif old_config["max_items"] ~= node_obj.config["max_items"] then
		if self.data[node] then
			local max_items = self.nodes[node].config["max_items"];
			if max_items == "max" then
				max_items = self.config.max_items;
			end
			self.data[node]:resize(max_items);
		end
	end

	return true;
end

function service:get_node_config(node, actor) --> (true, config) or (false, err)
	if not self:may(node, actor, "get_configuration") then
		return false, "forbidden";
	end

	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end

	local config_table = {};
	for k, v in pairs(default_node_config) do
		config_table[k] = v;
	end
	for k, v in pairs(self.node_defaults) do
		config_table[k] = v;
	end
	for k, v in pairs(node_obj.config) do
		config_table[k] = v;
	end

	return true, config_table;
end

function service:get_node_metadata(node, actor)
	if not self:may(node, actor, "get_metadata") then
		return false, "forbidden";
	end

	local ok, config = self:get_node_config(node, true);
	if not ok then return ok, config; end
	local meta = {};
	for _, k in ipairs(self.config.metadata_subset) do
		meta[k] = config[k];
	end
	return true, meta;
end

return {
	new = new;
};
