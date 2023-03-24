-- This module will "reset" the server when the client connection count drops
-- to zero. This is somewhere between a reload and a full process restart.
-- It is useful to ensure isolation between test runs, for example. It may
-- also be of use for some kinds of manual testing.

module:set_global();

local hostmanager = require "prosody.core.hostmanager";

local timer = require "prosody.util.timer";

local function do_reset()
	module:log("info", "Performing reset...");
	local hosts = {};
	for host in pairs(prosody.hosts) do
		table.insert(hosts, host);
	end
	module:fire_event("server-resetting");
	for _, host in ipairs(hosts) do
		hostmanager.deactivate(host);
		timer.add_task(0, function ()
			hostmanager.activate(host);
			module:log("info", "Reset complete");
			module:fire_event("server-reset");
		end);
	end
end

function module.add_host(host_module)
	host_module:hook("resource-unbind", function ()
		if next(prosody.full_sessions) == nil then
			timer.add_task(0, do_reset);
		end
	end);
end

local console_env = module:shared("/*/admin_shell/env");
console_env.debug_reset = {
	reset = do_reset;
};
