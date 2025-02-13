-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = module._log;

local require = require;
local pairs = pairs;
local s_find = string.find;
local tonumber = tonumber;

local core_post_stanza = prosody.core_post_stanza;
local core_process_stanza = prosody.core_process_stanza;
local st = require "prosody.util.stanza";
local jid_split = require "prosody.util.jid".split;
local jid_bare = require "prosody.util.jid".bare;
local datetime = require "prosody.util.datetime";
local hosts = prosody.hosts;
local bare_sessions = prosody.bare_sessions;
local full_sessions = prosody.full_sessions;
local NULL = {};

local rostermanager = require "prosody.core.rostermanager";
local sessionmanager = require "prosody.core.sessionmanager";

local recalc_resource_map = require "prosody.util.presence".recalc_resource_map;

local ignore_presence_priority = module:get_option_boolean("ignore_presence_priority", false);

local pre_approval_stream_feature = st.stanza("sub", {xmlns="urn:xmpp:features:pre-approval"});
module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if origin.username then
		features:add_child(pre_approval_stream_feature);
	end
end);

function handle_normal_presence(origin, stanza)
	if ignore_presence_priority then
		local priority = stanza:get_child("priority");
		if priority and priority[1] ~= "0" then
			for i=#priority.tags,1,-1 do priority.tags[i] = nil; end
			for i=#priority,2,-1 do priority[i] = nil; end
			priority[1] = "0";
		end
	end
	local priority = stanza:get_child_text("priority");
	if priority and s_find(priority, "^[+-]?[0-9]+$") then
		priority = tonumber(priority);
		if priority < -128 then priority = -128 end
		if priority > 127 then priority = 127 end
	else priority = 0; end

	local node, host = origin.username, origin.host;
	local roster = origin.roster;
	if full_sessions[origin.full_jid] then -- if user is still connected
		origin.send(stanza); -- reflect their presence back to them
	end
	local user = bare_sessions[node.."@"..host];
	for _, res in pairs(user and user.sessions or NULL) do -- broadcast to all resources
		if res ~= origin and res.presence then -- to resource
			stanza.attr.to = res.full_jid;
			core_post_stanza(origin, stanza, true);
		end
	end
	for jid, item in pairs(roster) do -- broadcast to all interested contacts
		if item.subscription == "both" or item.subscription == "from" then
			stanza.attr.to = jid;
			core_post_stanza(origin, stanza, true);
		end
	end

	-- It's possible that after the network activity above, the origin
	-- has been disconnected (particularly if something happened while
	-- sending the reflection). So we abort further presence processing
	-- in that case.
	if not origin.type then return; end

	stanza.attr.to = nil;
	if stanza.attr.type == nil and not origin.presence then -- initial presence
		module:fire_event("presence/initial", { origin = origin, stanza = stanza } );
		origin.presence = stanza; -- FIXME repeated later
		local probe = st.presence({from = origin.full_jid, type = "probe"});
		for jid, item in pairs(roster) do -- probe all contacts we are subscribed to
			if item.subscription == "both" or item.subscription == "to" then
				probe.attr.to = jid;
				core_post_stanza(origin, probe, true);
			end
		end
		for _, res in pairs(user and user.sessions or NULL) do -- broadcast from all available resources
			if res ~= origin and res.presence then
				res.presence.attr.to = origin.full_jid;
				core_post_stanza(res, res.presence, true);
				res.presence.attr.to = nil;
			end
		end
		for jid, pending_request in pairs(roster[false].pending) do -- resend incoming subscription requests
			if type(pending_request) == "table" then
				local subscribe = st.deserialize(pending_request);
				subscribe.attr.type, subscribe.attr.from = "subscribe", jid;
				origin.send(subscribe);
			else
				origin.send(st.presence({type="subscribe", from=jid}));
			end
		end
		local request = st.presence({type="subscribe", from=origin.username.."@"..origin.host});
		for jid, item in pairs(roster) do -- resend outgoing subscription requests
			if item.ask then
				request.attr.to = jid;
				core_post_stanza(origin, request, true);
			end
		end

		if priority >= 0 then
			local event = { origin = origin }
			module:fire_event('message/offline/broadcast', event);
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
				core_post_stanza(origin, stanza, true);
			end
			origin.directed = nil;
		end
	else
		origin.presence = stanza;
		stanza:tag("delay", { xmlns = "urn:xmpp:delay", from = host, stamp = datetime.datetime() }):up();
		if origin.priority ~= priority then
			origin.priority = priority;
			recalc_resource_map(user);
		end
	end
	stanza.attr.to = nil; -- reset it
end

-- luacheck: ignore 212/recipient_session
-- TODO This argument is used in 3rd party modules
function send_presence_of_available_resources(user, host, jid, recipient_session, stanza)
	local h = hosts[host];
	local count = 0;
	if h and h.type == "local" then
		local u = h.sessions[user];
		if u then
			for _, session in pairs(u.sessions) do
				local pres = session.presence;
				if pres then
					if stanza then pres = stanza; pres.attr.from = session.full_jid; end
					pres.attr.to = jid;
					core_post_stanza(session, pres, true);
					pres.attr.to = nil;
					count = count + 1;
				end
			end
		end
	end
	log("debug", "broadcasted presence of %d resources from %s@%s to %s", count, user, host, jid);
	return count;
end

function handle_outbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare)
	local node, host = jid_split(from_bare);
	if to_bare == from_bare then return; end -- No self contacts
	local st_from, st_to = stanza.attr.from, stanza.attr.to;
	stanza.attr.from, stanza.attr.to = from_bare, to_bare;
	log("debug", "outbound presence %s from %s for %s", stanza.attr.type, from_bare, to_bare);
	if stanza.attr.type == "probe" then
		stanza.attr.from, stanza.attr.to = st_from, st_to;
		return;
	elseif stanza.attr.type == "subscribe" then
		-- 1. route stanza
		-- 2. roster push (subscription = none, ask = subscribe)
		if rostermanager.set_contact_pending_out(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare);
		end -- else file error
		core_post_stanza(origin, stanza);
	elseif stanza.attr.type == "unsubscribe" then
		-- 1. route stanza
		-- 2. roster push (subscription = none or from)
		if rostermanager.unsubscribe(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare); -- FIXME do roster push when roster has in fact not changed?
		end -- else file error
		core_post_stanza(origin, stanza);
	elseif stanza.attr.type == "subscribed" then
		-- 1. route stanza
		-- 2. roster_push ()
		-- 3. send_presence_of_available_resources
		if rostermanager.subscribed(node, host, to_bare) then
			rostermanager.roster_push(node, host, to_bare);
		end
		if rostermanager.is_contact_subscribed(node, host, to_bare) then
			core_post_stanza(origin, stanza);
			send_presence_of_available_resources(node, host, to_bare, origin);
		end
		if rostermanager.is_user_subscribed(node, host, to_bare) then
			core_post_stanza(origin, st.presence({ type = "probe", from = from_bare, to = to_bare }));
		end
	elseif stanza.attr.type == "unsubscribed" then
		-- 1. send unavailable
		-- 2. route stanza
		-- 3. roster push (subscription = from or both)
		-- luacheck: ignore 211/pending_in
		-- Is pending_in meant to be used?
		local success, pending_in, subscribed = rostermanager.unsubscribed(node, host, to_bare);
		if success then
			if subscribed then
				rostermanager.roster_push(node, host, to_bare);
			end
			core_post_stanza(origin, stanza);
			if subscribed then
				send_presence_of_available_resources(node, host, to_bare, origin, st.presence({ type = "unavailable" }));
			end
		end
	else
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid presence type"));
	end
	stanza.attr.from, stanza.attr.to = st_from, st_to;
	return true;
end

function handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare)
	local node, host = jid_split(to_bare);
	local st_from, st_to = stanza.attr.from, stanza.attr.to;
	stanza.attr.from, stanza.attr.to = from_bare, to_bare;
	log("debug", "inbound presence %s from %s for %s", stanza.attr.type, from_bare, to_bare);

	if stanza.attr.type == "probe" then
		local result, err = rostermanager.is_contact_subscribed(node, host, from_bare);
		if result then
			if 0 == send_presence_of_available_resources(node, host, st_from, origin) then
				core_post_stanza(hosts[host], st.presence({from=to_bare, to=st_from, type="unavailable"}), true); -- TODO send last activity
			end
		elseif not err then
			core_post_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="unsubscribed"}), true);
		end
	elseif stanza.attr.type == "subscribe" then
		if rostermanager.is_contact_subscribed(node, host, from_bare) then
			core_post_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="subscribed"}), true); -- already subscribed
			-- Sending presence is not clearly stated in the RFC, but it seems appropriate
			if 0 == send_presence_of_available_resources(node, host, from_bare, origin) then
				core_post_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="unavailable"}), true); -- TODO send last activity
			end
		elseif rostermanager.is_contact_preapproved(node, host, from_bare) then
			if not rostermanager.is_contact_pending_in(node, host, from_bare) then
				if rostermanager.set_contact_pending_in(node, host, from_bare, stanza) then
					core_post_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="subscribed"}), true);
				end -- TODO else return error, unable to save
			end
		else
			core_post_stanza(hosts[host], st.presence({from=to_bare, to=from_bare, type="unavailable"}), true); -- acknowledging receipt
			if not rostermanager.is_contact_pending_in(node, host, from_bare) then
				if rostermanager.set_contact_pending_in(node, host, from_bare, stanza) then
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
	else
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid presence type"));
	end
	stanza.attr.from, stanza.attr.to = st_from, st_to;
	return true;
end

local outbound_presence_handler = function(data)
	-- outbound presence received
	local origin, stanza = data.origin, data.stanza;

	local to = stanza.attr.to;
	if to then
		local t = stanza.attr.type;
		if t ~= nil and t ~= "unavailable" and t ~= "error" then -- check for subscriptions and probes
			return handle_outbound_presence_subscriptions_and_probes(origin, stanza, jid_bare(stanza.attr.from), jid_bare(stanza.attr.to));
		end

		local to_bare = jid_bare(to);
		local roster = origin.roster;
		if roster and not(roster[to_bare] and (roster[to_bare].subscription == "both" or roster[to_bare].subscription == "from")) then -- directed presence
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
	-- inbound presence to bare JID received
	local origin, stanza = data.origin, data.stanza;

	local to = stanza.attr.to;
	local t = stanza.attr.type;
	if to then
		if t ~= nil and t ~= "unavailable" and t ~= "error" then -- check for subscriptions and probes sent to bare JID
			return handle_inbound_presence_subscriptions_and_probes(origin, stanza, jid_bare(stanza.attr.from), jid_bare(stanza.attr.to));
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
		handle_normal_presence(origin, stanza);
	else
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid presence type"));
	end
	return true;
end);
module:hook("presence/full", function(data)
	-- inbound presence to full JID received
	local origin, stanza = data.origin, data.stanza;

	local t = stanza.attr.type;
	if t ~= nil and t ~= "unavailable" and t ~= "error" then -- check for subscriptions and probes sent to full JID
		return handle_inbound_presence_subscriptions_and_probes(origin, stanza, jid_bare(stanza.attr.from), jid_bare(stanza.attr.to));
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
	local stanza = data.stanza;

	local from_bare = jid_bare(stanza.attr.from);
	local t = stanza.attr.type;
	if t == "probe" then
		core_post_stanza(hosts[module.host], st.presence({ from = module.host, to = from_bare, id = stanza.attr.id }));
	elseif t == "subscribe" then
		core_post_stanza(hosts[module.host], st.presence({ from = module.host, to = from_bare, id = stanza.attr.id, type = "subscribed" }));
		core_post_stanza(hosts[module.host], st.presence({ from = module.host, to = from_bare, id = stanza.attr.id }));
	end
	return true;
end);

module:hook("resource-unbind", function(event)
	local session, err = event.session, event.error;
	-- Send unavailable presence
	if session.presence then
		local pres = st.presence{ type = "unavailable" };
		if err then
			pres:tag("status"):text("Disconnected: "..err):up();
		end
		core_process_stanza(session, pres);
	elseif session.directed then
		local pres = st.presence{ type = "unavailable", from = session.full_jid };
		if err then
			pres:tag("status"):text("Disconnected: "..err):up();
		end
		for jid in pairs(session.directed) do
			pres.attr.to = jid;
			core_post_stanza(session, pres, true);
		end
		session.directed = nil;
	end
end);

module:hook("roster-item-removed", function (event)
	local username = event.username;
	local session = event.origin;
	local roster = event.roster or session and session.roster;
	local jid = event.jid;
	local item = event.item;
	local from_jid = session.full_jid or (username .. "@" .. module.host);

	local subscription = item and item.subscription or "none";
	local ask = item and item.ask;
	local pending = roster and roster[false].pending[jid];

	if subscription == "both" or subscription == "from" or pending then
		core_post_stanza(session, st.presence({type="unsubscribed", from=from_jid, to=jid}));
	end

	if subscription == "both" or subscription == "to" or ask then
		send_presence_of_available_resources(username, module.host, jid, session, st.presence({type="unavailable"}));
		core_post_stanza(session, st.presence({type="unsubscribe", from=from_jid, to=jid}));
	end

end, -1);

