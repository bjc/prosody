-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local log = require "util.logger".init("stanzarouter")

local hosts = _G.hosts;

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

local handle_outbound_presence_subscriptions_and_probes = function()end;--require "core.presencemanager".handle_outbound_presence_subscriptions_and_probes;
local handle_inbound_presence_subscriptions_and_probes = function()end;--require "core.presencemanager".handle_inbound_presence_subscriptions_and_probes;
local handle_normal_presence = function()end;--require "core.presencemanager".handle_normal_presence;

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
local fire_event = require "core.eventmanager2".fire_event;

function core_process_stanza(origin, stanza)
	(origin.log or log)("debug", "Received[%s]: %s", origin.type, stanza:top_tag())

	-- Currently we guarantee every stanza to have an xmlns, should we keep this rule?
	if not stanza.attr.xmlns then stanza.attr.xmlns = "jabber:client"; end
	
	-- TODO verify validity of stanza (as well as JID validity)
	if stanza.attr.type == "error" and #stanza.tags == 0 then return; end -- TODO invalid stanza, log
	if stanza.name == "iq" then
		if (stanza.attr.type == "set" or stanza.attr.type == "get") and #stanza.tags ~= 1 then
			origin.send(st.error_reply(stanza, "modify", "bad-request"));
			return;
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
			log("warn", "Received stanza with invalid destination JID: %s", to);
			origin.send(st.error_reply(stanza, "modify", "jid-malformed", "The destination address is invalid: "..to));
			return;
		end
		to_bare = node and (node.."@"..host) or host; -- bare JID
		if resource then to = to_bare.."/"..resource; else to = to_bare; end
		stanza.attr.to = to;
	end
	if from then
		-- We only stamp the 'from' on c2s stanzas, so we still need to check validity
		from_node, from_host, from_resource = jid_prepped_split(from);
		if not from_host then
			log("warn", "Received stanza with invalid source JID: %s", from);
			origin.send(st.error_reply(stanza, "modify", "jid-malformed", "The source address is invalid: "..from));
			return;
		end
		from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID
		if from_resource then from = from_bare.."/"..from_resource; else from = from_bare; end
		stanza.attr.from = from;
	end

	--[[if to and not(hosts[to]) and not(hosts[to_bare]) and (hosts[host] and hosts[host].type ~= "local") then -- not for us?
		log("warn", "stanza recieved for a non-local server");
		return; -- FIXME what should we do here?
	end]] -- FIXME

	if (origin.type == "s2sin" or origin.type == "c2s" or origin.type == "component") and xmlns == "jabber:client" then
		if origin.type == "s2sin" and not origin.dummy then
			local host_status = origin.hosts[from_host];
			if not host_status or not host_status.authed then -- remote server trying to impersonate some other server?
				log("warn", "Received a stanza claiming to be from %s, over a conn authed for %s!", from_host, origin.from_host);
				return; -- FIXME what should we do here? does this work with subdomains?
			end
		end
		core_post_stanza(origin, stanza);
	else
		modules_handle_stanza(host or origin.host or origin.to_host, origin, stanza);
	end
end

function core_post_stanza(origin, stanza)
	local to = stanza.attr.to;
	local node, host, resource = jid_split(to);
	local to_bare = node and (node.."@"..host) or host; -- bare JID

	local event_data = {origin=origin, stanza=stanza};
	if fire_event(tostring(host or origin.host).."/"..stanza.name, event_data) then
		-- event handled
	elseif not to then
		modules_handle_stanza(host or origin.host or origin.to_host, origin, stanza);
	elseif hosts[to] and hosts[to].type == "local" then -- directed at a local server
		modules_handle_stanza(host or origin.host or origin.to_host, origin, stanza);
	elseif hosts[to_bare] and hosts[to_bare].type == "component" then -- hack to allow components to handle node@server
		component_handle_stanza(origin, stanza);
	elseif hosts[host] and hosts[host].type == "component" then -- directed at a component
		component_handle_stanza(origin, stanza);
	elseif hosts[host] and hosts[host].type == "local" and stanza.name == "iq" and not resource then -- directed at bare JID
		modules_handle_stanza(host or origin.host or origin.to_host, origin, stanza);
	else
		core_route_stanza(origin, stanza);
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
	
	if hosts[to_bare] and hosts[to_bare].type == "component" then -- hack to allow components to handle node@server
		return component_handle_stanza(origin, stanza);
	elseif hosts[host] and hosts[host].type == "component" then -- directed at a component
		return component_handle_stanza(origin, stanza);
	end

	if stanza.name == "presence" and (stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" and stanza.attr.type ~= "error") then resource = nil; end

	local host_session = hosts[host]
	if host_session and host_session.type == "local" then
		-- Local host
		local user = host_session.sessions[node];
		if user then
			local res = user.sessions[resource];
			if res then -- resource is online...
				res.send(stanza); -- Yay \o/
			else
				-- if we get here, resource was not specified or was unavailable
				if stanza.name == "presence" then
					if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" and stanza.attr.type ~= "error" then
						handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza);
					elseif not resource then -- sender is available or unavailable or error
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
				elseif stanza.attr.type == "get" or stanza.attr.type == "set" then
					origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
				end
			end
		else
			-- user not online
			if user_exists(node, host) then
				if stanza.name == "presence" then
					if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" and stanza.attr.type ~= "error" then
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
				elseif stanza.name == "iq" and (stanza.attr.type == "get" or stanza.attr.type == "set") then
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
				elseif stanza.attr.type ~= "error" and (stanza.name ~= "iq" or stanza.attr.type ~= "result") then
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
