-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = module._log;

local require = require;
local pairs, ipairs = pairs, ipairs;
local t_concat = table.concat;
local s_find = string.find;
local tonumber = tonumber;

local st = require "util.stanza";
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local hosts = hosts;

local rostermanager = require "core.rostermanager";
local sessionmanager = require "core.sessionmanager";
local offlinemanager = require "core.offlinemanager";

local _core_route_stanza = core_route_stanza;
local core_route_stanza;
function core_route_stanza(origin, stanza)
	if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" and stanza.attr.type ~= "error" then
		local node, host = jid_split(stanza.attr.to);
		host = hosts[host];
		if host and host.type == "local" then
			handle_inbound_presence_subscriptions_and_probes(origin, stanza, jid_bare(stanza.attr.from), jid_bare(stanza.attr.to), core_route_stanza);
			return;
		end
	end
	_core_route_stanza(origin, stanza);
end

function handle_presence(origin, stanza, from_bare, to_bare, core_route_stanza, inbound)
	local type = stanza.attr.type;
	if type and type ~= "unavailable" and type ~= "error" then
		if inbound then
			handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza);
		else
			handle_outbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza);
		end
	elseif not inbound and not stanza.attr.to then
		handle_normal_presence(origin, stanza, core_route_stanza);
	else
		core_route_stanza(origin, stanza);
	end
end

function handle_normal_presence(origin, stanza, core_route_stanza)
	if origin.roster then
		for jid in pairs(origin.roster) do -- broadcast to all interested contacts
			local subscription = origin.roster[jid].subscription;
			if subscription == "both" or subscription == "from" then
				stanza.attr.to = jid;
				core_route_stanza(origin, stanza);
			end
		end
		local node, host = jid_split(stanza.attr.from);
		for _, res in pairs(hosts[host].sessions[node].sessions) do -- broadcast to all resources
			if res ~= origin and res.presence then -- to resource
				stanza.attr.to = res.full_jid;
				core_route_stanza(origin, stanza);
			end
		end
		if stanza.attr.type == nil and not origin.presence then -- initial presence
			local probe = st.presence({from = origin.full_jid, type = "probe"});
			for jid in pairs(origin.roster) do -- probe all contacts we are subscribed to
				local subscription = origin.roster[jid].subscription;
				if subscription == "both" or subscription == "to" then
					probe.attr.to = jid;
					core_route_stanza(origin, probe);
				end
			end
			for _, res in pairs(hosts[host].sessions[node].sessions) do -- broadcast from all available resources
				if res ~= origin and res.presence then
					res.presence.attr.to = origin.full_jid;
					core_route_stanza(res, res.presence);
					res.presence.attr.to = nil;
				end
			end
			if origin.roster.pending then -- resend incoming subscription requests
				for jid in pairs(origin.roster.pending) do
					origin.send(st.presence({type="subscribe", from=jid})); -- TODO add to attribute? Use original?
				end
			end
			local request = st.presence({type="subscribe", from=origin.username.."@"..origin.host});
			for jid, item in pairs(origin.roster) do -- resend outgoing subscription requests
				if item.ask then
					request.attr.to = jid;
					core_route_stanza(origin, request);
				end
			end
			local offline = offlinemanager.load(node, host);
			if offline then
				for _, msg in ipairs(offline) do
					origin.send(msg); -- FIXME do we need to modify to/from in any way?
				end
				offlinemanager.deleteAll(node, host);
			end
		end
		origin.priority = 0;
		if stanza.attr.type == "unavailable" then
			origin.presence = nil;
			if origin.directed then
				local old_from = stanza.attr.from;
				stanza.attr.from = origin.full_jid;
				for jid in pairs(origin.directed) do
					stanza.attr.to = jid;
					core_route_stanza(origin, stanza);
				end
				stanza.attr.from = old_from;
				origin.directed = nil;
			end
		else
			origin.presence = stanza;
			local priority = stanza:child_with_name("priority");
			if priority and #priority > 0 then
				priority = t_concat(priority);
				if s_find(priority, "^[+-]?[0-9]+$") then
					priority = tonumber(priority);
					if priority < -128 then priority = -128 end
					if priority > 127 then priority = 127 end
					origin.priority = priority;
				end
			end
		end
		stanza.attr.to = nil; -- reset it
	else
		log("warn", "presence recieved from client with no roster");
	end
end

function send_presence_of_available_resources(user, host, jid, recipient_session, core_route_stanza)
	local h = hosts[host];
	local count = 0;
	if h and h.type == "local" then
		local u = h.sessions[user];
		if u then
			for k, session in pairs(u.sessions) do
				local pres = session.presence;
				if pres then
					pres.attr.to = jid;
					core_route_stanza(session, pres);
					pres.attr.to = nil;
					count = count + 1;
				end
			end
		end
	end
	log("debug", "broadcasted presence of "..count.." resources from "..user.."@"..host.." to "..jid);
	return count;
end

function handle_outbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza)
	local node, host = jid_split(from_bare);
	local st_from, st_to = stanza.attr.from, stanza.attr.to;
	stanza.attr.from, stanza.attr.to = from_bare, to_bare;
	log("debug", "outbound presence "..stanza.attr.type.." from "..from_bare.." for "..to_bare);
	if stanza.attr.type == "subscribe" then
		-- 1. route stanza
		-- 2. roster push (subscription = none, ask = subscribe)
		if rostermanager.set_contact_pending_out(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare);
		end -- else file error
		core_route_stanza(origin, stanza);
	elseif stanza.attr.type == "unsubscribe" then
		-- 1. route stanza
		-- 2. roster push (subscription = none or from)
		if rostermanager.unsubscribe(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare); -- FIXME do roster push when roster has in fact not changed?
		end -- else file error
		core_route_stanza(origin, stanza);
	elseif stanza.attr.type == "subscribed" then
		-- 1. route stanza
		-- 2. roster_push ()
		-- 3. send_presence_of_available_resources
		if rostermanager.subscribed(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare);
		end
		core_route_stanza(origin, stanza);
		send_presence_of_available_resources(node, host, to_bare, origin, core_route_stanza);
	elseif stanza.attr.type == "unsubscribed" then
		-- 1. route stanza
		-- 2. roster push (subscription = none or to)
		if rostermanager.unsubscribed(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare);
		end
		core_route_stanza(origin, stanza);
	end
	stanza.attr.from, stanza.attr.to = st_from, st_to;
end

function handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza)
	local node, host = jid_split(to_bare);
	local st_from, st_to = stanza.attr.from, stanza.attr.to;
	stanza.attr.from, stanza.attr.to = from_bare, to_bare;
	log("debug", "inbound presence "..stanza.attr.type.." from "..from_bare.." for "..to_bare);
	if stanza.attr.type == "probe" then
		if rostermanager.is_contact_subscribed(node, host, from_bare) then
			if 0 == send_presence_of_available_resources(node, host, from_bare, origin, core_route_stanza) then
				-- TODO send last recieved unavailable presence (or we MAY do nothing, which is fine too)
			end
		else
			core_route_stanza(origin, st.presence({from=to_bare, to=from_bare, type="unsubscribed"}));
		end
	elseif stanza.attr.type == "subscribe" then
		if rostermanager.is_contact_subscribed(node, host, from_bare) then
			core_route_stanza(origin, st.presence({from=to_bare, to=from_bare, type="subscribed"})); -- already subscribed
			-- Sending presence is not clearly stated in the RFC, but it seems appropriate
			if 0 == send_presence_of_available_resources(node, host, from_bare, origin, core_route_stanza) then
				-- TODO send last recieved unavailable presence (or we MAY do nothing, which is fine too)
			end
		else
			if not rostermanager.is_contact_pending_in(node, host, from_bare) then
				if rostermanager.set_contact_pending_in(node, host, from_bare) then
					sessionmanager.send_to_available_resources(node, host, stanza);
				end -- TODO else return error, unable to save
			end
		end
	elseif stanza.attr.type == "unsubscribe" then
		if rostermanager.process_inbound_unsubscribe(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
		end
	elseif stanza.attr.type == "subscribed" then
		if rostermanager.process_inbound_subscription_approval(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
		end
	elseif stanza.attr.type == "unsubscribed" then
		if rostermanager.process_inbound_subscription_cancellation(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
		end
	end -- discard any other type
	stanza.attr.from, stanza.attr.to = st_from, st_to;
end

local function presence_handler(data)
	local origin, stanza = data.origin, data.stanza;
	local to = stanza.attr.to;
	local node, host = jid_split(to);
	local to_bare = jid_bare(to);
	local from_bare = jid_bare(stanza.attr.from);
	if origin.type == "c2s" then
		if to ~= nil and not(origin.roster[to_bare] and (origin.roster[to_bare].subscription == "both" or origin.roster[to_bare].subscription == "from")) then -- directed presence
			origin.directed = origin.directed or {};
			origin.directed[to] = true; -- FIXME does it make more sense to add to_bare rather than to?
		end
		if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" and stanza.attr.type ~= "error" then
			handle_outbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza);
		elseif not to then
			handle_normal_presence(origin, stanza, core_route_stanza);
		else
			core_route_stanza(origin, stanza);
		end
	elseif (origin.type == "s2sin" or origin.type == "component") and hosts[host] then
		if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" and stanza.attr.type ~= "error" then
			handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare, core_route_stanza);
		else
			core_route_stanza(origin, stanza);
		end
	end
	return true;
end

prosody.events.add_handler(module:get_host().."/presence", presence_handler);
module.unload = function()
	prosody.events.remove_handler(module:get_host().."/presence", presence_handler);
end

local outbound_presence_handler = function(data)
	-- outbound presence to recieved
	local origin, stanza = data.origin, data.stanza;

	local t = stanza.attr.type;
	if t ~= nil and t ~= "unavailable" and t ~= "error" then -- check for subscriptions and probes sent to full JID
		handle_outbound_presence_subscriptions_and_probes(origin, stanza, jid_bare(stanza.attr.from), jid_bare(stanza.attr.to), core_route_stanza);
		return true;
	end

	local to = stanza.attr.to;
	local to_bare = jid_bare(to);
	if not(origin.roster[to_bare] and (origin.roster[to_bare].subscription == "both" or origin.roster[to_bare].subscription == "from")) then -- directed presence
		origin.directed = origin.directed or {};
		if t then -- removing from directed presence list on sending an error or unavailable
			origin.directed[to] = nil; -- FIXME does it make more sense to add to_bare rather than to?
		else
			origin.directed[to] = true; -- FIXME does it make more sense to add to_bare rather than to?
		end
	end
end

module:hook("pre-presence/full", outbound_presence_handler);
module:hook("pre-presence/bare", outbound_presence_handler);
module:hook("pre-presence/host", outbound_presence_handler);

module:hook("presence/bare", function(data)
	-- inbound presence to bare JID recieved
	local origin, stanza = data.origin, data.stanza;
end);
module:hook("presence/full", function(data)
	-- inbound presence to full JID recieved
	local origin, stanza = data.origin, data.stanza;
end);
