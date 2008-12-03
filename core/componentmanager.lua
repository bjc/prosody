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




local log = require "util.logger".init("componentmanager")
local jid_split = require "util.jid".split;
local hosts = hosts;

local components = {};

module "componentmanager"

function handle_stanza(origin, stanza)
	local node, host = jid_split(stanza.attr.to);
	local component = components[host];
	if not component then component = components[node.."@"..host]; end -- hack to allow hooking node@server
	if not component then component = components[stanza.attr.to]; end -- hack to allow hooking node@server/resource and server/resource
	if component then
		log("debug", "stanza being handled by component: "..host);
		component(origin, stanza, hosts[host]);
	else
		log("error", "Component manager recieved a stanza for a non-existing component: " .. stanza.attr.to);
	end
end

function register_component(host, component)
	if not hosts[host] then
		-- TODO check for host well-formedness
		components[host] = component;
		hosts[host] = {type = "component", host = host, connected = true, s2sout = {} };
		log("debug", "component added: "..host);
		return hosts[host];
	else
		log("error", "Attempt to set component for existing host: "..host);
	end
end

return _M;
