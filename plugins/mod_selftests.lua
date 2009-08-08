-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module.host = "*" -- Global module

local st = require "util.stanza";
local register_component = require "core.componentmanager".register_component;
local core_route_stanza = core_route_stanza;
local socket = require "socket";
local ping_hosts = module:get_option("ping_hosts") or { "coversant.interop.xmpp.org", "djabberd.interop.xmpp.org", "djabberd-trunk.interop.xmpp.org", "ejabberd.interop.xmpp.org", "openfire.interop.xmpp.org" };

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
