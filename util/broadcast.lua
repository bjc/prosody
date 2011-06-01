-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local ipairs, pairs, setmetatable, type =
      ipairs, pairs, setmetatable, type;

module "pubsub"

local pubsub_node_mt = { __index = _M };

function new_node(name)
	return setmetatable({ name = name, subscribers = {} }, pubsub_node_mt);
end

function set_subscribers(node, subscribers_list, list_type)
	local subscribers = node.subscribers;
	
	if list_type == "array" then
		for _, jid in ipairs(subscribers_list) do
			if not subscribers[jid] then
				node:add_subscriber(jid);
			end
		end
	elseif (not list_type) or list_type == "set" then
		for jid in pairs(subscribers_list) do
			if type(jid) == "string" then
				node:add_subscriber(jid);
			end
		end
	end
end

function get_subscribers(node)
	return node.subscribers;
end

function publish(node, item, dispatcher, data)
	local subscribers = node.subscribers;
	for i = 1,#subscribers do
		item.attr.to = subscribers[i];
		dispatcher(data, item);
	end
end

function add_subscriber(node, jid)
	local subscribers = node.subscribers;
	if not subscribers[jid] then
		local space = #subscribers;
		subscribers[space] = jid;
		subscribers[jid] = space;
	end
end

function remove_subscriber(node, jid)
	local subscribers = node.subscribers;
	if subscribers[jid] then
		subscribers[subscribers[jid]] = nil;
		subscribers[jid] = nil;
	end
end

return _M;
