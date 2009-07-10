-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local t_insert = table.insert;
local ipairs = ipairs;

module "eventmanager"

local event_handlers = {};

function add_event_hook(name, handler)
	if not event_handlers[name] then
		event_handlers[name] = {};
	end
	t_insert(event_handlers[name] , handler);
end

function fire_event(name, ...)
	local event_handlers = event_handlers[name];
	if event_handlers then
		for name, handler in ipairs(event_handlers) do
			handler(...);
		end
	end
end

return _M;