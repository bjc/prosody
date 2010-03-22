-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local listeners_dir = (CFG_SOURCEDIR or ".").."/net/";
local server = require "net.server";
local log = require "util.logger".init("connlisteners");
local tostring = tostring;

local dofile, pcall, error = 
	dofile, pcall, error

module "connlisteners"

local listeners = {};

function register(name, listener)
	if listeners[name] and listeners[name] ~= listener then
		log("debug", "Listener %s is already registered, not registering any more", name);
		return false;
	end
	listeners[name] = listener;
	log("debug", "Registered connection listener %s", name);
	return true;
end

function deregister(name)
	listeners[name] = nil;
end

function get(name)
	local h = listeners[name];
	if not h then
		local ok, ret = pcall(dofile, listeners_dir..name:gsub("[^%w%-]", "_").."_listener.lua");
		if not ok then
			log("error", "Error while loading listener '%s': %s", tostring(name), tostring(ret));
			return nil, ret;
		end
		h = listeners[name];
	end
	return h;
end

function start(name, udata)
	local h, err = get(name);
	if not h then
		error("No such connection module: "..name.. (err and (" ("..err..")") or ""), 0);
	end
	
	if udata then
		if (udata.type == "ssl" or udata.type == "tls") and not udata.ssl then
			error("No SSL context supplied for a "..tostring(udata.type):upper().." connection!", 0);
		elseif udata.ssl and udata.type == "tcp" then
			error("SSL context supplied for a TCP connection!", 0);
		end
	end
	
	return server.addserver(h, 
			(udata and udata.port) or h.default_port or error("Can't start listener "..name.." because no port was specified, and it has no default port", 0), 
				(udata and udata.interface) or h.default_interface or "*", (udata and udata.mode) or h.default_mode or 1, (udata and udata.ssl) or nil, 99999999, udata and udata.type == "ssl");
end

return _M;
