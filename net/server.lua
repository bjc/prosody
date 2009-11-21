local have_luaevent = pcall(require, "luaevent.core");
local use_luaevent = require "core.configmanager".get("*", "core", "use_libevent");

local server;

if have_luaevent and use_luaevent == true then
	server = require "net.server_event";
	package.loaded["net.server"] = server;
	
	-- Backwards compatibility for timers, addtimer
	-- called a function roughly every second
	local add_task = require "util.timer";
	function server.addtimer(f)
		return add_task(1, function (...) f(...); return 1; end);
	end
else
	server = require "net.server_select";
	package.loaded["net.server"] = server;
end

return server;
