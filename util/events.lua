-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local pairs = pairs;
local t_insert = table.insert;
local t_remove = table.remove;
local t_sort = table.sort;
local setmetatable = setmetatable;
local next = next;

local _ENV = nil;

local function new()
	-- Map event name to ordered list of handlers (lazily built): handlers[event_name] = array_of_handler_functions
	local handlers = {};
	-- Array of wrapper functions that wrap all events (nil if empty)
	local global_wrappers;
	-- Per-event wrappers: wrappers[event_name] = wrapper_function
	local wrappers = {};
	-- Event map: event_map[handler_function] = priority_number
	local event_map = {};
	-- Called on-demand to build handlers entries
	local function _rebuild_index(handlers, event)
		local _handlers = event_map[event];
		if not _handlers or next(_handlers) == nil then return; end
		local index = {};
		for handler in pairs(_handlers) do
			t_insert(index, handler);
		end
		t_sort(index, function(a, b) return _handlers[a] > _handlers[b]; end);
		handlers[event] = index;
		return index;
	end;
	setmetatable(handlers, { __index = _rebuild_index });
	local function add_handler(event, handler, priority)
		local map = event_map[event];
		if map then
			map[handler] = priority or 0;
		else
			map = {[handler] = priority or 0};
			event_map[event] = map;
		end
		handlers[event] = nil;
	end;
	local function remove_handler(event, handler)
		local map = event_map[event];
		if map then
			map[handler] = nil;
			handlers[event] = nil;
			if next(map) == nil then
				event_map[event] = nil;
			end
		end
	end;
	local function get_handlers(event)
		return handlers[event];
	end;
	local function add_handlers(handlers)
		for event, handler in pairs(handlers) do
			add_handler(event, handler);
		end
	end;
	local function remove_handlers(handlers)
		for event, handler in pairs(handlers) do
			remove_handler(event, handler);
		end
	end;
	local function _fire_event(event_name, event_data)
		local h = handlers[event_name];
		if h then
			for i=1,#h do
				local ret = h[i](event_data);
				if ret ~= nil then return ret; end
			end
		end
	end;
	local function fire_event(event_name, event_data)
		local w = wrappers[event_name] or global_wrappers;
		if w then
			local curr_wrapper = #w;
			local function c(event_name, event_data)
				curr_wrapper = curr_wrapper - 1;
				if curr_wrapper == 0 then
					if global_wrappers == nil or w == global_wrappers then
						return _fire_event(event_name, event_data);
					end
					w, curr_wrapper = global_wrappers, #global_wrappers;
					return w[curr_wrapper](c, event_name, event_data);
				else
					return w[curr_wrapper](c, event_name, event_data);
				end
			end
			return w[curr_wrapper](c, event_name, event_data);
		end
		return _fire_event(event_name, event_data);
	end
	local function add_wrapper(event_name, wrapper)
		local w;
		if event_name == false then
			w = global_wrappers;
			if not w then
				w = {};
				global_wrappers = w;
			end
		else
			w = wrappers[event_name];
			if not w then
				w = {};
				wrappers[event_name] = w;
			end
		end
		w[#w+1] = wrapper;
	end
	local function remove_wrapper(event_name, wrapper)
		local w;
		if event_name == false then
			w = global_wrappers;
		else
			w = wrappers[event_name];
		end
		if not w then return; end
		for i = #w, 1 do
			if w[i] == wrapper then
				t_remove(w, i);
			end
		end
		if #w == 0 then
			if event_name == false then
				global_wrappers = nil;
			else
				wrappers[event_name] = nil;
			end
		end
	end
	return {
		add_handler = add_handler;
		remove_handler = remove_handler;
		add_handlers = add_handlers;
		remove_handlers = remove_handlers;
		get_handlers = get_handlers;
		wrappers = {
			add_handler = add_wrapper;
			remove_handler = remove_wrapper;
		};
		add_wrapper = add_wrapper;
		remove_wrapper = remove_wrapper;
		fire_event = fire_event;
		_handlers = handlers;
		_event_map = event_map;
	};
end

return {
	new = new;
};
