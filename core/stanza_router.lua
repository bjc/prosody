-- Prosody IM v0.3
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
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
local pairs = pairs;
local ipairs = ipairs;

local jid_split = require "util.jid".split;
local jid_prepped_split = require "util.jid".prepped_split;
local print = print;
local function checked_error_reply(origin, stanza)
	if (stanza.attr.xmlns == "jabber:client" or stanza.attr.xmlns == "jabber:server") and stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- FIXME correct error?
	end
end

function core_process_stanza(origin, stanza)
	(origin.log or log)("debug", "Received[%s]: %s", origin.type, stanza:top_tag())

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
	local from = stanza.attr.from;
	local node, host, resource;
	local from_node, from_host, from_resource;
	local to_bare, from_bare;
	if to then
		node, host, resource = jid_prepped_split(to);
		if not host then
			error("Invalid to JID");
		end
		to_bare = node and (node.."@"..host) or host; -- bare JID
		if resource then to = to_bare.."/"..resource; else to = to_bare; end
		stanza.attr.to = to;
	end
	if from then
		from_node, from_host, from_resource = jid_prepped_split(from);
		if not from_host then
			error("Invalid from JID");
		end
		from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID
		if from_resource then from = from_bare.."/"..from_resource; else from = from_bare; end
		stanza.attr.from = from;
	end

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
		if origin.type == "c2s" and stanza.name == "presence" and to ~= nil and not(origin.roster[to_bare] and (origin.roster[to_bare].subscription == "both" or origin.roster[to_bare].subscription == "from")) then -- directed presence
			origin.directed = origin.directed or {};
			origin.directed[to] = true;
			--t_insert(origin.directed, to); -- FIXME does it make more sense to add to_bare rather than to?
		end
		if not to then
			core_handle_stanza(origin, stanza);
		elseif hosts[to] and hosts[to].type == "local" then -- directed at a local server
			core_handle_stanza(origin, stanza);
		elseif stanza.attr.xmlns and stanza.attr.xmlns ~= "jabber:client" and stanza.attr.xmlns ~= "jabber:server" then
			modules_handle_stanza(host or origin.host or origin.to_host, origin, stanza);
		elseif hosts[to] and hosts[to].type == "component" then -- hack to allow components to handle node@server/resource and server/resource
			component_handle_stanza(origin, stanza);
		elseif hosts[to_bare] and hosts[to_bare].type == "component" then -- hack to allow components to handle node@server
			component_handle_stanza(origin, stanza);
		elseif hosts[host] and hosts[host].type == "component" then -- directed at a component
			component_handle_stanza(origin, stanza);
		elseif origin.type == "c2s" and stanza.name == "presence" and stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
			handle_outbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza);
		elseif hosts[host] and hosts[host].type == "local" and stanza.name == "iq" and not resource then -- directed at bare JID
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
	if modules_handle_stanza(select(2, jid_split(stanza.attr.to)) or origin.host, origin, stanza) then return; end
	if origin.type == "c2s" or origin.type == "s2sin" then
		if origin.type == "c2s" then
			if stanza.name == "presence" and origin.roster then
				if stanza.attr.type == nil or stanza.attr.type == "unavailable" then
					handle_normal_presence(origin, stanza, core_route_stanza);
				else
					log("warn", "Unhandled c2s presence: %s", tostring(stanza));
					checked_error_reply(origin, stanza);
				end
			else
				log("warn", "Unhandled c2s stanza: %s", tostring(stanza));
				checked_error_reply(origin, stanza);
			end
		else -- s2s stanzas
			log("warn", "Unhandled s2s stanza: %s", tostring(stanza));
			checked_error_reply(origin, stanza);
		end
	else
		log("warn", "Unhandled %s stanza: %s", origin.type, tostring(stanza));
		checked_error_reply(origin, stanza);
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
	
	if hosts[to] and hosts[to].type == "component" then -- hack to allow components to handle node@server/resource and server/resource
		return component_handle_stanza(origin, stanza);
	elseif hosts[to_bare] and hosts[to_bare].type == "component" then -- hack to allow components to handle node@server
		return component_handle_stanza(origin, stanza);
	elseif hosts[host] and hosts[host].type == "component" then -- directed at a component
		return component_handle_stanza(origin, stanza);
	end

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
					stanza.attr.to = to_bare;
					if stanza.attr.type == 'headline' then
						for _, session in pairs(user.sessions) do -- find resource with greatest priority
							if session.presence and session.priority >= 0 then
								session.send(stanza);
							end
						end
					elseif resource and stanza.attr.type == 'groupchat' then
						-- Groupchat message sent to offline resource
						origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
					else
						local priority = 0;
						local recipients = {};
						for _, session in pairs(user.sessions) do -- find resource with greatest priority
							if session.presence then
								local p = session.priority;
								if p > priority then
									priority = p;
									recipients = {session};
								elseif p == priority then
									t_insert(recipients, session);
								end
							end
						end
						local count = 0;
						for _, session in ipairs(recipients) do
							session.send(stanza);
							count = count + 1;
						end
						if count == 0 and (stanza.attr.type == "chat" or stanza.attr.type == "normal" or not stanza.attr.type) then
							offlinemanager.store(node, host, stanza);
							-- TODO deal with storage errors
						end
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
				elseif stanza.name == "message" then -- FIXME if full jid, then send out to resources with highest priority
					stanza.attr.to = to_bare; -- TODO not in RFC, but seems obvious. Should discuss on the mailing list.
					if stanza.attr.type == "chat" or stanza.attr.type == "normal" or not stanza.attr.type then
						offlinemanager.store(node, host, stanza);
						-- FIXME don't store messages with only chat state notifications
					elseif stanza.attr.type == "groupchat" then
						local reply = st.error_reply(stanza, "cancel", "service-unavailable");
						reply.attr.from = to;
						origin.send(reply);
					end
					-- TODO allow configuration of offline storage
					-- TODO send error if not storing offline
				elseif stanza.name == "iq" then
					origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
				end
			else -- user does not exist
				-- TODO we would get here for nodeless JIDs too. Do something fun maybe? Echo service? Let plugins use xmpp:server/resource addresses?
				if stanza.name == "presence" then
					local t = stanza.attr.type;
					if t == "subscribe" or t == "probe" then
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
