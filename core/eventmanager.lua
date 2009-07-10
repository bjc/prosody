
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