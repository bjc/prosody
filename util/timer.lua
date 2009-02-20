-- Prosody IM v0.3
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local ns_addtimer = require "net.server".addtimer;
local get_time = os.time;
local t_insert = table.insert;
local ipairs = ipairs;
local type = type;

local data = {};
local new_data = {};

module "timer"

local function _add_task(delay, func)
	local current_time = get_time();
	delay = delay + current_time;
	if delay >= current_time then
		t_insert(new_data, {delay, func});
	else func(); end
end

add_task = _add_task;

ns_addtimer(function()
	local current_time = get_time();
	for _, d in ipairs(new_data) do
		t_insert(data, d);
	end
	new_data = {};
	for i = #data,1 do
		local t, func = data[i][1], data[i][2];
		if t <= current_time then
			data[i] = nil;
			local r = func();
			if type(r) == "number" then _add_task(r, func); end
		end
	end
end);

return _M;
