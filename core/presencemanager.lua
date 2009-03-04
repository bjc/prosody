-- Prosody IM v0.3
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local log = require "util.logger".init("presencemanager")

local require = require;
local pairs, ipairs = pairs, ipairs;
local t_concat = table.concat;
local s_find = string.find;
local tonumber = tonumber;

local st = require "util.stanza";
local jid_split = require "util.jid".split;
local hosts = hosts;

local rostermanager = require "core.rostermanager";
local sessionmanager = require "core.sessionmanager";
local offlinemanager = require "core.offlinemanager";

module "presencemanager"

function handle_presence(origin, stanza, from_bare, to_bare, core_route_stanza, inbound)
	local type = stanza.attr.type;
	if type and type ~= "unavailable" then
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
			if res ~= origin and res.full_jid then -- to resource. FIXME is res.full_jid the correct check? Maybe it should be res.presence
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
		log("error", "presence recieved from client with no roster");
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
					pres.attr.from = session.full_jid;
					core_route_stanza(session, pres);
					pres.attr.to = nil;
					pres.attr.from = nil;
					count = count + 1;
				end
			end
		end
	end
	log("info", "broadcasted presence of "..count.." resources from "..user.."@"..host.." to "..jid);
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

return _M;
