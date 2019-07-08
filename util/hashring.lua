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

function hashring_methods:add_node(name)
	self.ring = nil;
	self.nodes[name] = true;
	table.insert(self.nodes, name);
	return true;
end

function hashring_methods:add_nodes(nodes)
	self.ring = nil;
	for _, node_name in ipairs(nodes) do
		if not self.nodes[node_name] then
			self.nodes[node_name] = true;
			table.insert(self.nodes, node_name);
		end
	end
	return true;
end

function hashring_methods:remove_node(node_name)
	self.ring = nil;
	if self.nodes[node_name] then
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
	clone_hashring:add_nodes(self.nodes);
	return clone_hashring;
end

function hashring_methods:get_node(key)
	local key_hash = self.hash(key);
	for _, replica_hash in ipairs(self.ring) do
		if key_hash < replica_hash then
			return self.ring[replica_hash];
		end
	end
	return self.ring[self.ring[1]];
end

return {
	new = new;
}
