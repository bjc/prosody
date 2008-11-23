
local log = require "util.logger".init("presencemanager")

local require = require;
local pairs = pairs;

local st = require "util.stanza";
local jid_split = require "util.jid".split;
local hosts = hosts;

local rostermanager = require "core.rostermanager";
local sessionmanager = require "core.sessionmanager";

module "presencemanager"

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
