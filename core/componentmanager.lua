-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = require "util.logger".init("componentmanager");
local prosody, hosts = prosody, prosody.hosts;

local components = {};

module "componentmanager"

function register_component(host, component)
	if hosts[host] and hosts[host].type == 'component' then
		components[host] = component;
		log("debug", "component added: "..host);
		return hosts[host];
	else
		log("error", "Attempt to set component for existing host: "..host);
	end
end

function deregister_component(host)
	if components[host] then
		components[host] = nil;
		log("debug", "component removed: "..host);
		return true;
	else
		log("error", "Attempt to remove component for non-existing host: "..host);
	end
end

return _M;
