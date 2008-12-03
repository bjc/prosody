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



local st = require "util.stanza";
local register_component = require "core.componentmanager".register_component;
local core_route_stanza = core_route_stanza;
local socket = require "socket";
local config = require "core.configmanager";
local ping_hosts = config.get("*", "mod_selftests", "ping_hosts") or { "coversant.interop.xmpp.org", "djabberd.interop.xmpp.org", "djabberd-trunk.interop.xmpp.org", "ejabberd.interop.xmpp.org", "openfire.interop.xmpp.org" };

local open_pings = {};

local t_insert = table.insert;

local log = require "util.logger".init("mod_selftests");

local tests_jid = "self_tests@getjabber.ath.cx";
local host = "getjabber.ath.cx";

if not (tests_jid and host) then
	for currhost in pairs(host) do
		if currhost ~= "localhost" then
			tests_jid, host = "self_tests@"..currhost, currhost;
		end
	end
end

if tests_jid and host then
	local bot = register_component(tests_jid, 	function(origin, stanza, ourhost)
										local time = open_pings[stanza.attr.id];
										
										if time then
											log("info", "Ping reply from %s in %fs", tostring(stanza.attr.from), socket.gettime() - time);
										else
											log("info", "Unexpected reply: %s", stanza:pretty_print());
										end
									end);


	local our_origin = hosts[host];
	module:add_event_hook("server-started", 
					function ()
						local id = st.new_id();
						local ping_attr = { xmlns = 'urn:xmpp:ping' };
						local function send_ping(to)
							log("info", "Sending ping to %s", to);
							core_route_stanza(our_origin, st.iq{ to = to, from = tests_jid, id = id, type = "get" }:tag("ping", ping_attr));
							open_pings[id] = socket.gettime();
						end
						
						for _, host in ipairs(ping_hosts) do
							send_ping(host);
						end
					end);
end
