-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local t_insert, t_remove = table.insert, table.remove;

module "filters"

local new_filter_hooks = {};

function initialize(session)
	if not session.filters then
		local filters = {};
		session.filters = filters;
		
		function session.filter(type, data)
			local filter_list = filters[type];
			if filter_list then
				for i = 1, #filter_list do
					data = filter_list[i](data, session);
					if data == nil then break; end
				end
			end
			return data;
		end
	end
	
	for i=1,#new_filter_hooks do
		new_filter_hooks[i](session);
	end
	
	return session.filter;
end

function add_filter(session, type, callback, priority)
	if not session.filters then
		initialize(session);
	end
	
	local filter_list = session.filters[type];
	if not filter_list then
		filter_list = {};
		session.filters[type] = filter_list;
	end
	
	priority = priority or 0;
	
	local i = 0;
	repeat
		i = i + 1;
	until not filter_list[i] or filter_list[filter_list[i]] >= priority;
	
	t_insert(filter_list, i, callback);
	filter_list[callback] = priority;
end

function remove_filter(session, type, callback)
	if not session.filters then return; end
	local filter_list = session.filters[type];
	if filter_list and filter_list[callback] then
		for i=1, #filter_list do
			if filter_list[i] == callback then
				t_remove(filter_list, i);
				filter_list[callback] = nil;
				return true;
			end
		end
	end
end

function add_filter_hook(callback)
	t_insert(new_filter_hooks, callback);
end

function remove_filter_hook(callback)
	for i=1,#new_filter_hooks do
		if new_filter_hooks[i] == callback then
			t_remove(new_filter_hooks, i);
		end
	end
end

return _M;
