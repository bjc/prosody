-- Prosody IM v0.2
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



local helper = require "util.discohelper".new();
local hosts = hosts;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local usermanager_user_exists = require "core.usermanager".user_exists;
local rostermanager_is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local print = print;

do
	helper:addDiscoInfoHandler("*host", function(reply, to, from, node)
		if hosts[to] then
			reply:tag("identity", {category="server", type="im", name="Prosody"}):up();
			return true;
		end
	end);
	helper:addDiscoInfoHandler("*node", function(reply, to, from, node)
		local node, host = jid_split(to);
		if hosts[host] and rostermanager_is_contact_subscribed(node, host, jid_bare(from)) then
			reply:tag("identity", {category="account", type="registered"}):up();
			return true;
		end
	end);
	helper:addDiscoItemsHandler("*host", function(reply, to, from, node)
		if hosts[to] and hosts[to].type == "local" then
			return true;
		end
	end);
end

module "discomanager"

function handle(stanza)
	return helper:handle(stanza);
end

function addDiscoItemsHandler(jid, func)
	return helper:addDiscoItemsHandler(jid, func);
end

function addDiscoInfoHandler(jid, func)
	return helper:addDiscoInfoHandler(jid, func);
end

function set(plugin, var, origin)
	-- TODO handle origin and host based on plugin.
	local handler = function(reply, to, from, node) -- service discovery
		if #node == 0 then
			reply:tag("feature", {var = var}):up();
			return true;
		end
	end
	addDiscoInfoHandler("*node", handler);
	addDiscoInfoHandler("*host", handler);
end

return _M;
