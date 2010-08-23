-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local use_luaevent = prosody and require "core.configmanager".get("*", "core", "use_libevent");

if use_luaevent then
	use_luaevent = pcall(require, "luaevent.core");
	if not use_luaevent then
		log("error", "libevent not found, falling back to select()");
	end
end

local server;

if use_luaevent then
	server = require "net.server_event";
	-- util.timer requires "net.server", so instead of having
	-- Lua look for, and load us again (causing a loop) - set this here
	-- (usually it isn't set until we return, look down there...)
	package.loaded["net.server"] = server;
	
	-- Backwards compatibility for timers, addtimer
	-- called a function roughly every second
	local add_task = require "util.timer".add_task;
	function server.addtimer(f)
		return add_task(1, function (...) f(...); return 1; end);
	end
	
	-- Overwrite signal.signal() because we need to ask libevent to
	-- handle them instead
	local ok, signal = pcall(require, "util.signal");
	if ok and signal then
		local _signal_signal = signal.signal;
		function signal.signal(signal_id, handler)
			if type(signal_id) == "string" then
				signal_id = signal[signal_id:upper()];
			end
			if type(signal_id) ~= "number" then
				return false, "invalid-signal";
			end
			return server.hook_signal(signal_id, handler);
		end
	end
else
	server = require "net.server_select";
	package.loaded["net.server"] = server;
end

-- require "net.server" shall now forever return this,
-- ie. server_select or server_event as chosen above.
return server;
