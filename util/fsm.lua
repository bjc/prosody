local events = require "prosody.util.events";

local fsm_methods = {};
local fsm_mt = { __index = fsm_methods };

local function is_fsm(o)
	local mt = getmetatable(o);
	return mt == fsm_mt;
end

local function notify_transition(fire_event, transition_event)
	local ret;
	ret = fire_event("transition", transition_event);
	if ret ~= nil then return ret; end
	if transition_event.from ~= transition_event.to then
		ret = fire_event("leave/"..transition_event.from, transition_event);
		if ret ~= nil then return ret; end
	end
	ret = fire_event("transition/"..transition_event.name, transition_event);
	if ret ~= nil then return ret; end
end

local function notify_transitioned(fire_event, transition_event)
	if transition_event.to ~= transition_event.from then
		fire_event("enter/"..transition_event.to, transition_event);
	end
	if transition_event.name then
		fire_event("transitioned/"..transition_event.name, transition_event);
	end
	fire_event("transitioned", transition_event);
end

local function do_transition(name)
	return function (self, attr)
		local new_state = self.fsm.states[self.state][name] or self.fsm.states["*"][name];
		if not new_state then
			return error(("Invalid state transition: %s cannot %s"):format(self.state, name));
		end

		local transition_event = {
			instance = self;

			name = name;
			to = new_state;
			to_attr = attr;

			from = self.state;
			from_attr = self.state_attr;
		};

		local fire_event = self.fsm.events.fire_event;
		local ret = notify_transition(fire_event, transition_event);
		if ret ~= nil then return nil, ret; end

		self.state = new_state;
		self.state_attr = attr;

		notify_transitioned(fire_event, transition_event);
		return true;
	end;
end

local function new(desc)
	local self = setmetatable({
		default_state = desc.default_state;
		events = events.new();
	}, fsm_mt);

	-- states[state_name][transition_name] = new_state_name
	local states = { ["*"] = {} };
	if desc.default_state then
		states[desc.default_state] = {};
	end
	self.states = states;

	local instance_methods = {};
	self._instance_mt = { __index = instance_methods };

	for _, transition in ipairs(desc.transitions or {}) do
		local from_states = transition.from;
		if type(from_states) ~= "table" then
			from_states = { from_states };
		end
		for _, from in ipairs(from_states) do
			if not states[from] then
				states[from] = {};
			end
			if not states[transition.to] then
				states[transition.to] = {};
			end
			if states[from][transition.name] then
				return error(("Duplicate transition in FSM specification: %s from %s"):format(transition.name, from));
			end
			states[from][transition.name] = transition.to;
		end

		-- Add public method to trigger this transition
		instance_methods[transition.name] = do_transition(transition.name);
	end

	if desc.state_handlers then
		for state_name, handler in pairs(desc.state_handlers) do
			self.events.add_handler("enter/"..state_name, handler);
		end
	end

	if desc.transition_handlers then
		for transition_name, handler in pairs(desc.transition_handlers) do
			self.events.add_handler("transition/"..transition_name, handler);
		end
	end

	if desc.handlers then
		self.events.add_handlers(desc.handlers);
	end

	return self;
end

function fsm_methods:init(state_name, state_attr)
	local initial_state = assert(state_name or self.default_state, "no initial state specified");
	if not self.states[initial_state] then
		return error("Invalid initial state: "..initial_state);
	end
	local instance = setmetatable({
		fsm = self;
		state = initial_state;
		state_attr = state_attr;
	}, self._instance_mt);

	if initial_state ~= self.default_state then
		local fire_event = self.events.fire_event;
		notify_transitioned(fire_event, {
			instance = instance;

			to = initial_state;
			to_attr = state_attr;

			from = self.default_state;
		});
	end

	return instance;
end

function fsm_methods:is_instance(o)
	local mt = getmetatable(o);
	return mt == self._instance_mt;
end

return {
	new = new;
	is_fsm = is_fsm;
};
