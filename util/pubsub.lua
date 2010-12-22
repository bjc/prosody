module("pubsub", package.seeall);

local service = {};
local service_mt = { __index = service };

local default_config = {
	broadcaster = function () end;
	get_affiliation = function () end;
	capabilities = {};
};

function new(config)
	config = config or {};
	return setmetatable({
		config = setmetatable(config, { __index = default_config });
		affiliations = {};
		nodes = {};
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
	
	local node_capabilities = node_obj and node_obj.capabilities;
	local service_capabilities = self.config.capabilities;
	
	-- Check if node allows/forbids it	
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
	local _, jid_sub = self:get_subscription(node, nil, jid);
	if not jid_sub and not self:may(node, jid, "be_unsubscribed") then
		local ok, err = self:add_subscription(node, nil, jid);
		if not ok then
			return ok, err;
		end
	elseif jid_sub and not self:may(node, jid, "be_subscribed") then
		local ok, err = self:add_subscription(node, nil, jid);
		if not ok then
			return ok, err;
		end
	end
	return true;
end

function service:add_subscription(node, actor, jid, options)
	-- Access checking
	local cap;
	if jid == actor or self:jids_equal(actor, jid) then
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
			local ok, err = self:create(node, actor);
			if not ok then
				return ok, err;
			end
			node_obj = self.nodes[node];
		end
	end
	node_obj.subscribers[jid] = options or true;
	return true;
end

function service:remove_subscription(node, actor, jid)
	-- Access checking
	local cap;
	if jid == actor or self:jids_equal(actor, jid) then
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
	return true;
end

function service:get_subscription(node, actor, jid)
	-- Access checking
	local cap;
	if jid == actor or self:jids_equal(actor, jid) then
		cap = "get_subscription";
	else
		cap = "get_subscription_other";
	end
	if not self:may(node, actor, cap) then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if node_obj then
		return true, node_obj.subscribers[jid];
	end
end

function service:create(node, actor)
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
		config = {};
		data = {};
		affiliations = {};
	};
	local ok, err = self:set_affiliation(node, true, actor, "owner");
	if not ok then
		self.nodes[node] = nil;
	end
	return ok, err;
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
		local ok, err = self:create(node, actor);
		if not ok then
			return ok, err;
		end
		node_obj = self.nodes[node];
	end
	node_obj.data[id] = item;
	self.config.broadcaster(node, node_obj.subscribers, item);
	return true;
end

function service:retract(node, actor, id, retract)
	-- Access checking
	if not self:may(node, actor, "retract") then
		return false, "forbidden";
	end
	--
	local node_obj = self.nodes[node];
	if (not node_obj) or (not node_obj.data[id]) then
		return false, "item-not-found";
	end
	node_obj.data[id] = nil;
	if retract then
		self.config.broadcaster(node, node_obj.subscribers, retract);
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
		return true, { [id] = node_obj.data[id] };
	else
		return true, node_obj.data;
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

return _M;
