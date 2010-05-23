-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = module._log;

local require = require;
local pairs, ipairs = pairs, ipairs;
local t_concat, t_insert = table.concat, table.insert;
local s_find = string.find;
local tonumber = tonumber;

local st = require "util.stanza";
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local hosts = hosts;
local NULL = {};

local rostermanager = require "core.rostermanager";
local sessionmanager = require "core.sessionmanager";
local offlinemanager = require "core.offlinemanager";

local _core_route_stanza = core_route_stanza;
local core_route_stanza;
function core_route_stanza(origin, stanza)
	if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" and stanza.attr.type ~= "error" then
		local node, host = jid_split(stanza.attr.to);
		host = hosts[host];
		if node and host and host.type == "local" then
			handle_inbound_presence_subscriptions_and_probes(origin, stanza, jid_bare(stanza.attr.from), jid_bare(stanza.attr.to), core_route_stanza);
			return;
		end
	end
	_core_route_stanza(origin, stanza);
end

local function select_top_resources(user)
	local priority = 0;
	local recipients = {};
	for _, session in pairs(user.sessions) do -- find resource with greatest priority
		if session.presence then
			-- TODO check active privacy list for session
			local p = session.priority;
			if p > priority then
				priority = p;
				recipients = {session};
			elseif p == priority then
				t_insert(recipients, session);
			end
		end
	end
	return recipients;
end
local function recalc_resource_map(user)
	if user then
		user.top_resources = select_top_resources(user);
		if #user.top_resources == 0 then user.top_resources = nil; end
	end
end

local ignore_presence_priority = module:get_option("ignore_presence_priority");

function handle_normal_presence(origin, stanza, core_route_stanza)
	if ignore_presence_priority then
		local priority = stanza:child_with_name("priority");
		if priority and priority[1] ~= "0" then
			for i=#priority.tags,1,-1 do priority.tags[i] = nil; end
			for i=#priority,1,-1 do priority[i] = nil; end
			priority[1] = "0";
		end
	end
	if full_sessions[origin.full_jid] then -- if user is still connected
		origin.send(stanza); -- reflect their presence back to them
	end
	local roster = origin.roster;
	local node, host = origin.username, origin.host;
	local user = bare_sessions[node.."@"..host];
	for _, res in pairs(user and user.sessions or NULL) do -- broadcast to all resources
		if res ~= origin and res.presence then -- to resource
			stanza.attr.to = res.full_jid;
			core_route_stanza(origin, stanza);
		end
	end
	for jid, item in pairs(roster) do -- broadcast to all interested contacts
		if item.subscription == "both" or item.subscription == "from" then
			stanza.attr.to = jid;
			core_route_stanza(origin, stanza);
		end
	end
	if stanza.attr.type == nil and not origin.presence then -- initial presence
		origin.presence = stanza; -- FIXME repeated later
		local probe = st.presence({from = origin.full_jid, type = "probe"});
		for jid, item in pairs(roster) do -- probe all contacts we are subscribed to
			if item.subscription == "both" or item.subscription == "to" then
				probe.attr.to = jid;
				core_route_stanza(origin, probe);
			end
		end
		for _, res in pairs(user and user.sessions or NULL) do -- broadcast from all available resources
			if res ~= origin and res.presence then
				res.presence.attr.to = origin.full_jid;
				core_route_stanza(res, res.presence);
				res.presence.attr.to = nil;
			end
		end
		if roster.pending then -- resend incoming subscription requests
			for jid in pairs(roster.pending) do
				origin.send(st.presence({type="subscribe", from=jid})); -- TODO add to attribute? Use original?
			end
		end
		local request = st.presence({type="subscribe", from=origin.username.."@"..origin.host});
		for jid, item in pairs(roster) do -- resend outgoing subscription requests
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
	if stanza.attr.type == "unavailable" then
		origin.presence = nil;
		if origin.priority then
			origin.priority = nil;
			recalc_resource_map(user);
		end
		if origin.directed then
			for jid in pairs(origin.directed) do
				stanza.attr.to = jid;
				core_route_stanza(origin, stanza);
			end
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
			else priority = 0; end
		else priority = 0; end
		if origin.priority ~= priority then
			origin.priority = priority;
			recalc_resource_map(user);
		end
	end
	stanza.attr.to = nil; -- reset it
end

function send_presence_of_available_resources(user, host, jid, recipient_session, core_route_stanza, stanza)
	local h = hosts[host];
	local count = 0;
	if h and h.type == "local" then
		local u = h.sessions[user];
		if u then
			for k, session in pairs(u.sessions) do
				local pres = session.presence;
				if pres then
					if stanza then pres = stanza; pres.attr.from = session.full_jid; end
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
	if to_bare == origin.username.."@"..origin.host then return; end -- No self contacts
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
		local result, err = rostermanager.is_contact_subscribed(node, host, from_bare);
		if result then
			if 0 == send_presence_of_available_resources(node, host, st_from, origin, core_route_stanza) then
				core_route_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="unavailable"})); -- TODO send last activity
			end
		elseif not err then
			core_route_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="unsubscribed"}));
		end
	elseif stanza.attr.type == "subscribe" then
		if rostermanager.is_contact_subscribed(node, host, from_bare) then
			core_route_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="subscribed"})); -- already subscribed
			-- Sending presence is not clearly stated in the RFC, but it seems appropriate
			if 0 == send_presence_of_available_resources(node, host, from_bare, origin, core_route_stanza) then
				core_route_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="unavailable"})); -- TODO send last activity
			end
		else
			core_route_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="unavailable"})); -- acknowledging receipt
			if not rostermanager.is_contact_pending_in(node, host, from_bare) then
				if rostermanager.set_contact_pending_in(node, host, from_bare) then
					sessionmanager.send_to_available_resources(node, host, stanza);
				end -- TODO else return error, unable to save
			end
		end
	elseif stanza.attr.type == "unsubscribe" then
		if rostermanager.process_inbound_unsubscribe(node, host, from_bare) then
			sessionmanager.send_to_interested_resources(node, host, stanza);
			rostermanager.roster_push(node, host, from_bare);
		end
	elseif stanza.attr.type == "subscribed" then
		if rostermanager.process_inbound_subscription_approval(node, host, from_bare) then
			sessionmanager.send_to_interested_resources(node, host, stanza);
			rostermanager.roster_push(node, host, from_bare);
		end
	elseif stanza.attr.type == "unsubscribed" then
		if rostermanager.process_inbound_subscription_cancellation(node, host, from_bare) then
			sessionmanager.send_to_interested_resources(node, host, stanza);
			rostermanager.roster_push(node, host, from_bare);
		end
	end -- discard any other type
	stanza.attr.from, stanza.attr.to = st_from, st_to;
end

local outbound_presence_handler = function(data)
	-- outbound presence recieved
	local origin, stanza = data.origin, data.stanza;

	local to = stanza.attr.to;
	if to then
		local t = stanza.attr.type;
		if t ~= nil and t ~= "unavailable" and t ~= "error" then -- check for subscriptions and probes
			handle_outbound_presence_subscriptions_and_probes(origin, stanza, jid_bare(stanza.attr.from), jid_bare(stanza.attr.to), core_route_stanza);
			return true;
		end

		local to_bare = jid_bare(to);
		if not(origin.roster[to_bare] and (origin.roster[to_bare].subscription == "both" or origin.roster[to_bare].subscription == "from")) then -- directed presence
			origin.directed = origin.directed or {};
			if t then -- removing from directed presence list on sending an error or unavailable
				origin.directed[to] = nil; -- FIXME does it make more sense to add to_bare rather than to?
			else
				origin.directed[to] = true; -- FIXME does it make more sense to add to_bare rather than to?
			end
		end
	end -- TODO maybe handle normal presence here, instead of letting it pass to incoming handlers?
end

module:hook("pre-presence/full", outbound_presence_handler);
module:hook("pre-presence/bare", outbound_presence_handler);
module:hook("pre-presence/host", outbound_presence_handler);

module:hook("presence/bare", function(data)
	-- inbound presence to bare JID recieved
	local origin, stanza = data.origin, data.stanza;

	local to = stanza.attr.to;
	local t = stanza.attr.type;
	if to then
		if t ~= nil and t ~= "unavailable" and t ~= "error" then -- check for subscriptions and probes sent to bare JID
			handle_inbound_presence_subscriptions_and_probes(origin, stanza, jid_bare(stanza.attr.from), jid_bare(stanza.attr.to), core_route_stanza);
			return true;
		end
	
		local user = bare_sessions[to];
		if user then
			for _, session in pairs(user.sessions) do
				if session.presence then -- only send to available resources
					session.send(stanza);
				end
			end
		end -- no resources not online, discard
	elseif not t or t == "unavailable" then
		handle_normal_presence(origin, stanza, core_route_stanza);
	end
	return true;
end);
module:hook("presence/full", function(data)
	-- inbound presence to full JID recieved
	local origin, stanza = data.origin, data.stanza;

	local t = stanza.attr.type;
	if t ~= nil and t ~= "unavailable" and t ~= "error" then -- check for subscriptions and probes sent to full JID
		handle_inbound_presence_subscriptions_and_probes(origin, stanza, jid_bare(stanza.attr.from), jid_bare(stanza.attr.to), core_route_stanza);
		return true;
	end

	local session = full_sessions[stanza.attr.to];
	if session then
		-- TODO fire post processing event
		session.send(stanza);
	end -- resource not online, discard
	return true;
end);
module:hook("presence/host", function(data)
	-- inbound presence to the host
	local origin, stanza = data.origin, data.stanza;
	
	local from_bare = jid_bare(stanza.attr.from);
	local t = stanza.attr.type;
	if t == "probe" then
		core_route_stanza(hosts[module.host], st.presence({ from = module.host, to = from_bare, id = stanza.attr.id }));
	elseif t == "subscribe" then
		core_route_stanza(hosts[module.host], st.presence({ from = module.host, to = from_bare, id = stanza.attr.id, type = "subscribed" }));
		core_route_stanza(hosts[module.host], st.presence({ from = module.host, to = from_bare, id = stanza.attr.id }));
	end
	return true;
end);

module:hook("resource-unbind", function(event)
	local session, err = event.session, event.error;
	-- Send unavailable presence
	if session.presence then
		local pres = st.presence{ type = "unavailable" };
		if not(err) or err == "closed" then err = "connection closed"; end
		pres:tag("status"):text("Disconnected: "..err):up();
		session:dispatch_stanza(pres);
	elseif session.directed then
		local pres = st.presence{ type = "unavailable", from = session.full_jid };
		if not(err) or err == "closed" then err = "connection closed"; end
		pres:tag("status"):text("Disconnected: "..err):up();
		for jid in pairs(session.directed) do
			pres.attr.to = jid;
			core_route_stanza(session, pres);
		end
		session.directed = nil;
	end
end);
