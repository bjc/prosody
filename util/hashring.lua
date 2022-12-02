local it = require "util.iterators";

local function generate_ring(nodes, num_replicas, hash)
	local new_ring = {};
	for _, node_name in ipairs(nodes) do
		for replica = 1, num_replicas do
			local replica_hash = hash(node_name..":"..replica);
			new_ring[replica_hash] = node_name;
			table.insert(new_ring, replica_hash);
		end
	end
	table.sort(new_ring);
	return new_ring;
end

local hashring_methods = {};
local hashring_mt = {
	__index = function (self, k)
		-- Automatically build self.ring if it's missing
		if k == "ring" then
			local ring = generate_ring(self.nodes, self.num_replicas, self.hash);
			rawset(self, "ring", ring);
			return ring;
		end
		return rawget(hashring_methods, k);
	end
};

local function new(num_replicas, hash_function)
	return setmetatable({ nodes = {}, num_replicas = num_replicas, hash = hash_function }, hashring_mt);
end;

function hashring_methods:add_node(name, value)
	self.ring = nil;
	self.nodes[name] = value == nil and true or value;
	table.insert(self.nodes, name);
	return true;
end

function hashring_methods:add_nodes(nodes)
	self.ring = nil;
	local iter = pairs;
	if nodes[1] then -- simple array?
		iter = it.values;
	end
	for node_name, node_value in iter(nodes) do
		if self.nodes[node_name] == nil then
			self.nodes[node_name] = node_value == nil and true or node_value;
			table.insert(self.nodes, node_name);
		end
	end
	return true;
end

function hashring_methods:remove_node(node_name)
	self.ring = nil;
	if self.nodes[node_name] ~= nil then
		for i, stored_node_name in ipairs(self.nodes) do
			if node_name == stored_node_name then
				self.nodes[node_name] = nil;
				table.remove(self.nodes, i);
				return true;
			end
		end
	end
	return false;
end

function hashring_methods:remove_nodes(nodes)
	self.ring = nil;
	for _, node_name in ipairs(nodes) do
		self:remove_node(node_name);
	end
end

function hashring_methods:clone()
	local clone_hashring = new(self.num_replicas, self.hash);
	for node_name, node_value in pairs(self.nodes) do
		clone_hashring.nodes[node_name] = node_value;
	end
	clone_hashring.ring = nil;
	return clone_hashring;
end

function hashring_methods:get_node(key)
	local node;
	local key_hash = self.hash(key);
	for _, replica_hash in ipairs(self.ring) do
		if key_hash < replica_hash then
			node = self.ring[replica_hash];
			break;
		end
	end
	if not node then
		node = self.ring[self.ring[1]];
	end
	return node, self.nodes[node];
end

return {
	new = new;
}
