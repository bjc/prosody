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



local log = require "util.logger".init("stanzarouter")

local st = require "util.stanza";
local send_s2s = require "core.s2smanager".send_to_host;
local user_exists = require "core.usermanager".user_exists;

local rostermanager = require "core.rostermanager";
local sessionmanager = require "core.sessionmanager";
local offlinemanager = require "core.offlinemanager";

local s2s_verify_dialback = require "core.s2smanager".verify_dialback;
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;

local modules_handle_stanza = require "core.modulemanager".handle_stanza;
local component_handle_stanza = require "core.componentmanager".handle_stanza;

local handle_outbound_presence_subscriptions_and_probes = require "core.presencemanager".handle_outbound_presence_subscriptions_and_probes;
local handle_inbound_presence_subscriptions_and_probes = require "core.presencemanager".handle_inbound_presence_subscriptions_and_probes;
local handle_normal_presence = require "core.presencemanager".handle_normal_presence;

local format = string.format;
local tostring = tostring;
local t_concat = table.concat;
local t_insert = table.insert;
local tonumber = tonumber;
local s_find = string.find;

local jid_split = require "util.jid".split;
local print = print;

function core_process_stanza(origin, stanza)
	(origin.log or log)("debug", "Received[%s]: %s", origin.type, stanza:pretty_print()) --top_tag())

	if not stanza.attr.xmlns then stanza.attr.xmlns = "jabber:client"; end -- FIXME Hack. This should be removed when we fix namespace handling.
	-- TODO verify validity of stanza (as well as JID validity)
	if stanza.name == "iq" and not(#stanza.tags == 1 and stanza.tags[1].attr.xmlns) then
		if stanza.attr.type == "set" or stanza.attr.type == "get" then
			error("Invalid IQ");
		elseif #stanza.tags > 1 and not(stanza.attr.type == "error" or stanza.attr.type == "result") then
			error("Invalid IQ");
		end
	end

	if origin.type == "c2s" and not origin.full_jid
		and not(stanza.name == "iq" and stanza.tags[1].name == "bind"
				and stanza.tags[1].attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind") then
		error("Client MUST bind resource after auth");
	end

	-- TODO also, stanzas should be returned to their original state before the function ends
	if origin.type == "c2s" then
		stanza.attr.from = origin.full_jid;
	end
	local to, xmlns = stanza.attr.to, stanza.attr.xmlns;
	local node, host, resource = jid_split(to);
	local to_bare = node and (node.."@"..host) or host; -- bare JID
	local from = stanza.attr.from;
	local from_node, from_host, from_resource = jid_split(from);
	local from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID

	--[[if to and not(hosts[to]) and not(hosts[to_bare]) and (hosts[host] and hosts[host].type ~= "local") then -- not for us?
		log("warn", "stanza recieved for a non-local server");
		return; -- FIXME what should we do here?
	end]] -- FIXME

	-- FIXME do stanzas not of jabber:client get handled by components?
	if (origin.type == "s2sin" or origin.type == "c2s") and (not xmlns or xmlns == "jabber:server" or xmlns == "jabber:client") then			
		if origin.type == "s2sin" and not origin.dummy then
			local host_status = origin.hosts[from_host];
			if not host_status or not host_status.authed then -- remote server trying to impersonate some other server?
				log("warn", "Received a stanza claiming to be from %s, over a conn authed for %s!", from_host, origin.from_host);
				return; -- FIXME what should we do here? does this work with subdomains?
			end
		end
		if not to then
			core_handle_stanza(origin, stanza);
		elseif hosts[to] and hosts[to].type == "local" then -- directed at a local server
			core_handle_stanza(origin, stanza);
		elseif stanza.attr.xmlns and stanza.attr.xmlns ~= "jabber:client" and stanza.attr.xmlns ~= "jabber:server" then
			modules_handle_stanza(host or origin.host or origin.to_host, origin, stanza);
		elseif hosts[to_bare] and hosts[to_bare].type == "component" then -- hack to allow components to handle node@server
			component_handle_stanza(origin, stanza);
		elseif hosts[to] and hosts[to].type == "component" then -- hack to allow components to handle node@server/resource and server/resource
			component_handle_stanza(origin, stanza);
		elseif hosts[host] and hosts[host].type == "component" then -- directed at a component
			component_handle_stanza(origin, stanza);
		elseif origin.type == "c2s" and stanza.name == "presence" and stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
			handle_outbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza);
		elseif origin.type ~= "c2s" and stanza.name == "iq" and not resource then -- directed at bare JID
			core_handle_stanza(origin, stanza);
		else
			core_route_stanza(origin, stanza);
		end
	else
		core_handle_stanza(origin, stanza);
	end
end

-- This function handles stanzas which are not routed any further,
-- that is, they are handled by this server
function core_handle_stanza(origin, stanza)
	-- Handlers
	if modules_handle_stanza(stanza.attr.to or origin.host, origin, stanza) then return; end
	if origin.type == "c2s" or origin.type == "s2sin" then
		if origin.type == "c2s" then
			if stanza.name == "presence" and origin.roster then
				if stanza.attr.type == nil or stanza.attr.type == "unavailable" then
					handle_normal_presence(origin, stanza, core_route_stanza);
				else
					log("warn", "Unhandled c2s presence: %s", tostring(stanza));
					if (stanza.attr.xmlns == "jabber:client" or stanza.attr.xmlns == "jabber:server") and stanza.attr.type ~= "error" then
						origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- FIXME correct error?
					end
				end
			else
				log("warn", "Unhandled c2s stanza: %s", tostring(stanza));
				if (stanza.attr.xmlns == "jabber:client" or stanza.attr.xmlns == "jabber:server") and stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
					origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- FIXME correct error?
				end
			end
		else -- s2s stanzas
			log("warn", "Unhandled s2s stanza: %s", tostring(stanza));
			if (stanza.attr.xmlns == "jabber:client" or stanza.attr.xmlns == "jabber:server") and stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
				origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- FIXME correct error?
			end
		end
	else
		log("warn", "Unhandled %s stanza: %s", origin.type, tostring(stanza));
	end
end

function core_route_stanza(origin, stanza)
	-- Hooks
	--- ...later

	-- Deliver
	local to = stanza.attr.to;
	local node, host, resource = jid_split(to);
	local to_bare = node and (node.."@"..host) or host; -- bare JID
	local from = stanza.attr.from;
	local from_node, from_host, from_resource = jid_split(from);
	local from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID

	-- Auto-detect origin if not specified
	origin = origin or hosts[from_host];
	if not origin then return false; end
	
	if stanza.name == "presence" and (stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable") then resource = nil; end

	local host_session = hosts[host]
	if host_session and host_session.type == "local" then
		-- Local host
		local user = host_session.sessions[node];
		if user then
			local res = user.sessions[resource];
			if not res then
				-- if we get here, resource was not specified or was unavailable
				if stanza.name == "presence" then
					if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
						handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza);
					else -- sender is available or unavailable
						for _, session in pairs(user.sessions) do -- presence broadcast to all user resources.
							if session.full_jid then -- FIXME should this be just for available resources? Do we need to check subscription?
								stanza.attr.to = session.full_jid; -- reset at the end of function
								session.send(stanza);
							end
						end
					end
				elseif stanza.name == "message" then -- select a resource to recieve message
					local priority = 0;
					local recipients = {};
					for _, session in pairs(user.sessions) do -- find resource with greatest priority
						local p = session.priority;
						if p > priority then
							priority = p;
							recipients = {session};
						elseif p == priority then
							t_insert(recipients, session);
						end
					end
					local count = 0;
					for _, session in pairs(recipients) do
						session.send(stanza);
						count = count + 1;
					end
					if count == 0 then
						offlinemanager.store(node, host, stanza);
						-- TODO deal with storage errors
					end
				else
					-- TODO send IQ error
				end
			else
				-- User + resource is online...
				stanza.attr.to = res.full_jid; -- reset at the end of function
				res.send(stanza); -- Yay \o/
			end
		else
			-- user not online
			if user_exists(node, host) then
				if stanza.name == "presence" then
					if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
						handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza);
					else
						-- TODO send unavailable presence or unsubscribed
					end
				elseif stanza.name == "message" then
					if stanza.attr.type == "chat" or stanza.attr.type == "normal" or not stanza.attr.type then
						offlinemanager.store(node, host, stanza);
						-- FIXME don't store messages with only chat state notifications
					end
					-- TODO allow configuration of offline storage
					-- TODO send error if not storing offline
				elseif stanza.name == "iq" then
					-- TODO send IQ error
				end
			else -- user does not exist
				-- TODO we would get here for nodeless JIDs too. Do something fun maybe? Echo service? Let plugins use xmpp:server/resource addresses?
				if stanza.name == "presence" then
					if stanza.attr.type == "probe" then
						origin.send(st.presence({from = to_bare, to = from_bare, type = "unsubscribed"}));
					end
					-- else ignore
				else
					origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
				end
			end
		end
	elseif origin.type == "c2s" then
		-- Remote host
		local xmlns = stanza.attr.xmlns;
		--stanza.attr.xmlns = "jabber:server";
		stanza.attr.xmlns = nil;
		log("debug", "sending s2s stanza: %s", tostring(stanza));
		send_s2s(origin.host, host, stanza); -- TODO handle remote routing errors
		stanza.attr.xmlns = xmlns; -- reset
	elseif origin.type == "component" or origin.type == "local" then
		-- Route via s2s for components and modules
		log("debug", "Routing outgoing stanza for %s to %s", origin.host, host);
		send_s2s(origin.host, host, stanza);
	else
		log("warn", "received stanza from unhandled connection type: %s", origin.type);
	end
	stanza.attr.to = to; -- reset
end
