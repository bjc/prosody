-- Prosody IM v0.1
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--



local listeners_dir = (CFG_SOURCEDIR or ".").."/net/";
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

function get(name)
	local h = listeners[name];
	if not h then
		pcall(dofile, listeners_dir..name:gsub("[^%w%-]", "_").."_listener.lua");
		h = listeners[name];
	end
	return h;
end

function start(name, udata)
	local h = get(name);
	if not h then
		error("No such connection module: "..name, 0);
	end
	return server_add(h, 
			(udata and udata.port) or h.default_port or error("Can't start listener "..name.." because no port was specified, and it has no default port", 0), 
				(udata and udata.interface) or "*", (udata and udata.mode) or h.default_mode or 1, (udata and udata.ssl) or nil );
end

return _M;
