
local server_add = require "net.server".add;
local log = require "util.logger".init("connlisteners");

local dofile, pcall, error = 
	dofile, pcall, error

module "connlisteners"

local listeners = {};

function register(name, listener)
	if listeners[name] and listeners[name] ~= listener then
		log("warning", "Listener %s is already registered, not registering any more", name);
		return false;
	end
	listeners[name] = listener;
	log("info", "Registered connection listener %s", name);
	return true;
end

function deregister(name)
	listeners[name] = nil;
end

function start(name, udata)
	local h = listeners[name]
	if not h then
		pcall(dofile, "net/"..name:gsub("[^%w%-]", "_").."_listener.lua");
		h = listeners[name];
		if not h then
			error("No such connection module: "..name, 0);
		end
	end
	return server_add(h, 
			udata.port or h.default_port or error("Can't start listener "..name.." because no port was specified, and it has no default port", 0), 
				udata.interface or "*", udata.mode or h.default_mode or 1, udata.ssl );
end

return _M;