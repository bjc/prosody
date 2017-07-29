local events = require "util.events";
local cache = require "util.cache";

local service = {};
local service_mt = { __index = service };

local default_config = { __index = {
	itemstore = function (config, _) return cache.new(tonumber(config["pubsub#max_items"])) end;
	broadcaster = function () end;
	get_affiliation = function () end;
	capabilities = {};
} };
local default_node_config = { __index = {
	["pubsub#max_items"] = "20";
} };

local function new(config)
	config = config or {};
	return setmetatable({
		config = setmetatable(config, default_config);
		node_defaults = setmetatable(config.node_defaults or {}, default_node_config);
		affiliations = {};
		subscriptions = {};
		nodes = {};
		data = {};
		events = events.new();
	}, service_mt);
end

function service:jids_equal(jid1, jid2)
	local normalize = self.config.normalize_jid;
	return normalize(jid1) == normalize(jid2);
end

function service:may(node, actor, action)
	if actor == true then return true; end

	local node_obj = self.nodes[node];
	local node_aff = node_obj and node_obj.affiliations[actor];
	local service_aff = self.affiliations[actor]
	                 or self.config.get_affiliation(actor, node, action)
	                 or "none";

	-- Check if node allows/forbids it
	local node_capabilities = node_obj and node_obj.capabilities;
	if node_capabilities then
		local caps = node_capabilities[node_aff or service_aff];
		if caps then
			local can = caps[action];
			if can ~= nil then
				return can;
			end
		end
	end

	-- Check service-wide capabilities instead
	local service_capabilities = self.config.capabilities;
	local caps = service_capabilities[node_aff or service_aff];
	if caps then
		local can = caps[action];
		if can ~= nil then
			return can;
		end
	end

	return false;
end

function service:set_affiliation(node, actor, jid, affiliation)
	-- Access checking
	if not self:may(node, actor, "set_affiliation") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	node_obj.affiliations[jid] = affiliation;
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

function service:add_subscription(node, actor, jid, options)
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
	self.events.fire_event("subscription-added", { node = node, jid = jid, normalized_jid = normal_jid, options = options });
	return true;
end

function service:remove_subscription(node, actor, jid)
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
	self.events.fire_event("subscription-removed", { node = node, jid = jid, normalized_jid = normal_jid });
	return true;
end

function service:remove_all_subscriptions(actor, jid)
	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid]
	subs = subs and subs[jid];
	if subs then
		for node in pairs(subs) do
			self:remove_subscription(node, true, jid);
		end
	end
	return true;
end

function service:get_subscription(node, actor, jid)
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

function service:create(node, actor, options)
	-- Access checking
	if not self:may(node, actor, "create") then
		return false, "forbidden";
	end
	--
	if self.nodes[node] then
		return false, "conflict";
	end

	self.nodes[node] = {
		name = node;
		subscribers = {};
		config = setmetatable(options or {}, {__index=self.node_defaults});
		affiliations = {};
	};
	self.data[node] = self.config.itemstore(self.nodes[node].config, node);
	self.events.fire_event("node-created", { node = node, actor = actor });
	local ok, err = self:set_affiliation(node, true, actor, "owner");
	if not ok then
		self.nodes[node] = nil;
		self.data[node] = nil;
	end
	return ok, err;
end

function service:delete(node, actor)
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
	self.data[node] = nil;
	self.events.fire_event("node-deleted", { node = node, actor = actor });
	self.config.broadcaster("delete", node, node_obj.subscribers);
	return true;
end

function service:publish(node, actor, id, item)
	-- Access checking
	if not self:may(node, actor, "publish") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		if not self.config.autocreate_on_publish then
			return false, "item-not-found";
		end
		local ok, err = self:create(node, true);
		if not ok then
			return ok, err;
		end
		node_obj = self.nodes[node];
	end
	local node_data = self.data[node];
	if type(actor) == "string" then
		item.attr.publisher = actor;
	end
	local ok = node_data:set(id, item);
	if not ok then
		return nil, "internal-server-error";
	end
	if type(ok) == "string" then id = ok; end
	self.events.fire_event("item-published", { node = node, actor = actor, id = id, item = item });
	self.config.broadcaster("items", node, node_obj.subscribers, item, actor);
	return true;
end

function service:retract(node, actor, id, retract)
	-- Access checking
	if not self:may(node, actor, "retract") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if (not node_obj) or (not self.data[node]:get(id)) then
		return false, "item-not-found";
	end
	local ok = self.data[node]:set(id, nil);
	if not ok then
		return nil, "internal-server-error";
	end
	self.events.fire_event("item-retracted", { node = node, actor = actor, id = id });
	if retract then
		self.config.broadcaster("items", node, node_obj.subscribers, retract);
	end
	return true
end

function service:purge(node, actor, notify)
	-- Access checking
	if not self:may(node, actor, "retract") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	self.data[node] = self.config.itemstore(self.nodes[node].config, node);
	self.events.fire_event("node-purged", { node = node, actor = actor });
	if notify then
		self.config.broadcaster("purge", node, node_obj.subscribers);
	end
	return true
end

function service:get_items(node, actor, id)
	-- Access checking
	if not self:may(node, actor, "get_items") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	if id then -- Restrict results to a single specific item
		return true, { id, [id] = self.data[node]:get(id) };
	else
		local data = {}
		for key, value in self.data[node]:items() do
			data[#data+1] = key;
			data[key] = value;
		end
		return true, data;
	end
end

function service:get_nodes(actor)
	-- Access checking
	if not self:may(nil, actor, "get_nodes") then
		return false, "forbidden";
	end
	--
	return true, self.nodes;
end

function service:get_subscriptions(node, actor, jid)
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
	local normal_jid = self.config.normalize_jid(jid);
	local subs = self.subscriptions[normal_jid];
	-- We return the subscription object from the node to save
	-- a get_subscription() call for each node.
	local ret = {};
	if subs then
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
				local nodes = self.nodes;
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
	return true, ret;
end

-- Access models only affect 'none' affiliation caps, service/default access level...
function service:set_node_capabilities(node, actor, capabilities)
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

function service:set_node_config(node, actor, new_config)
	if not self:may(node, actor, "configure") then
		return false, "forbidden";
	end

	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end

	for k,v in pairs(new_config) do
		node_obj.config[k] = v;
	end
	local new_data = self.config.itemstore(self.nodes[node].config, node);
	for key, value in self.data[node]:items() do
		new_data:set(key, value);
	end
	self.data[node] = new_data;
	return true;
end

return {
	new = new;
};
