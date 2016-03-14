-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local t_insert = table.insert;

local function select_top_resources(user)
	local priority = 0;
	local recipients = {};
	for _, session in pairs(user.sessions) do -- find resource with greatest priority
		if session.presence then
			-- TODO check active privacy list for session
			local p = session.priority;
			if p > priority then
				priority = p;
				recipients = {session};
			elseif p == priority then
				t_insert(recipients, session);
			end
		end
	end
	return recipients;
end
local function recalc_resource_map(user)
	if user then
		user.top_resources = select_top_resources(user);
		if #user.top_resources == 0 then user.top_resources = nil; end
	end
end

return {
	select_top_resources = select_top_resources;
	recalc_resource_map = recalc_resource_map;
}
