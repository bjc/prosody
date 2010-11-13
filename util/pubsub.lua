module("pubsub", package.seeall);

local service = {};
local service_mt = { __index = service };

function new(cb)
	return setmetatable({ cb = cb or {}, nodes = {} }, service_mt);
end

function service:add_subscription(node, actor, jid)
	local node_obj = self.nodes[node];
	if not node_obj then
		return false, "item-not-found";
	end
	node_obj.subscribers[jid] = true;
	return true;
end

function service:remove_subscription(node, actor, jid)
	self.nodes[node].subscribers[jid] = nil;
	return true;
end

function service:get_subscription(node, actor, jid)
	local node_obj = self.nodes[node];
	if node_obj then
		return node_obj.subscribers[jid];
	end
end

function service:publish(node, actor, id, item)
	local node_obj = self.nodes[node];
	if not node_obj then
		node_obj = { name = node, subscribers = {}, config = {} };
		self.nodes[node] = node_obj;
	end
	node_obj.data = item;
	self.cb.broadcaster(node, node_obj.subscribers, item);
	return true;
end

return _M;
