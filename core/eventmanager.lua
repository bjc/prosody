-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local t_insert = table.insert;
local ipairs = ipairs;

local events = _G.prosody.events;

module "eventmanager"

local event_handlers = {};

function add_event_hook(name, handler)
	return events.add_handler(name, handler);
end

function fire_event(name, ...)
	return events.fire_event(name, ...);
end

return _M;
