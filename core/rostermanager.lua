-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: globals prosody.bare_sessions.?.roster



local log = require "prosody.util.logger".init("rostermanager");

local new_id = require "prosody.util.id".short;
local new_cache = require "prosody.util.cache".new;

local pairs = pairs;
local tostring = tostring;
local type = type;

local hosts = prosody.hosts;
local bare_sessions = prosody.bare_sessions;

local um_user_exists = require "prosody.core.usermanager".user_exists;
local st = require "prosody.util.stanza";
local storagemanager = require "prosody.core.storagemanager";

local _ENV = nil;
-- luacheck: std none

local save_roster; -- forward declaration

local function add_to_roster(session, jid, item)
	if session.roster then
		local old_item = session.roster[jid];
		session.roster[jid] = item;
		if save_roster(session.username, session.host, nil, jid) then
			return true;
		else
			session.roster[jid] = old_item;
			return nil, "wait", "internal-server-error", "Unable to save roster";
		end
	else
		return nil, "auth", "not-authorized", "Session's roster not loaded";
	end
end

local function remove_from_roster(session, jid)
	if session.roster then
		local old_item = session.roster[jid];
		session.roster[jid] = nil;
		if save_roster(session.username, session.host, nil, jid) then
			return true;
		else
			session.roster[jid] = old_item;
			return nil, "wait", "internal-server-error", "Unable to save roster";
		end
	else
		return nil, "auth", "not-authorized", "Session's roster not loaded";
	end
end

local function roster_push(username, host, jid)
	local roster = jid and hosts[host] and hosts[host].sessions[username] and hosts[host].sessions[username].roster;
	if roster then
		local item = hosts[host].sessions[username].roster[jid];
		local stanza = st.iq({type="set", id=new_id()});
		stanza:tag("query", {xmlns = "jabber:iq:roster", ver = tostring(roster[false].version or "1")  });
		if item then
			stanza:tag("item", {jid = jid, subscription = item.subscription, name = item.name, ask = item.ask});
			for group in pairs(item.groups) do
				stanza:tag("group"):text(group):up();
			end
		else
			stanza:tag("item", {jid = jid, subscription = "remove"});
		end
		stanza:up(); -- move out from item
		stanza:up(); -- move out from stanza
		-- stanza ready
		for _, session in pairs(hosts[host].sessions[username].sessions) do
			if session.interested then
				session.send(stanza);
			end
		end
	end
end

local function roster_metadata(roster, err)
	local metadata = roster[false];
	if not metadata then
		metadata = { broken = err or nil };
		roster[false] = metadata;
	end
	if roster.pending and type(roster.pending.subscription) ~= "string" then
		metadata.pending = roster.pending;
		roster.pending = nil;
	elseif not metadata.pending then
		metadata.pending = {};
	end
	return metadata;
end

local function load_roster(username, host)
	local jid = username.."@"..host;
	log("debug", "load_roster: asked for: %s", jid);
	local user = bare_sessions[jid];
	local roster;
	if user then
		roster = user.roster;
		if roster then return roster; end
		log("debug", "load_roster: loading for new user: %s", jid);
	else -- Attempt to load roster for non-loaded user
		log("debug", "load_roster: loading for offline user: %s", jid);
	end
	local roster_cache = hosts[host] and hosts[host].roster_cache;
	if not roster_cache then
		if hosts[host] then
			roster_cache = new_cache(1024);
			hosts[host].roster_cache = roster_cache;
		end
	else
		roster = roster_cache:get(jid);
		if roster then
			log("debug", "load_roster: cache hit");
			roster_cache:set(jid, roster);
			if user then user.roster = roster; end
			return roster;
		else
			log("debug", "load_roster: cache miss, loading from storage");
		end
	end
	local roster_store = storagemanager.open(host, "roster", "keyval");
	local data, err = roster_store:get(username);
	roster = data or {};
	if user then user.roster = roster; end
	local legacy_pending = roster.pending and type(roster.pending.subscription) ~= "string";
	roster_metadata(roster, err);
	if legacy_pending then
		-- Due to map store use, we need to manually delete this entry
		log("debug", "Removing legacy 'pending' entry");
		if not save_roster(username, host, roster, "pending") then
			log("warn", "Could not remove legacy 'pending' entry");
		end
	end
	if roster[jid] then
		roster[jid] = nil;
		log("debug", "Roster for %s had a self-contact, removing", jid);
		if not save_roster(username, host, roster, jid) then
			log("warn", "Could not remove self-contact from roster for %s", jid);
		end
	end
	if not err then
		hosts[host].events.fire_event("roster-load", { username = username, host = host, roster = roster });
	end
	if roster_cache and not user then
		log("debug", "load_roster: caching loaded roster");
		roster_cache:set(jid, roster);
	end
	return roster, err;
end

function save_roster(username, host, roster, jid)
	if not um_user_exists(username, host) then
		log("debug", "not saving roster for %s@%s: the user doesn't exist", username, host);
		return nil;
	end

	log("debug", "save_roster: saving roster for %s@%s, (%s)", username, host, jid or "all contacts");
	if not roster then
		roster = hosts[host] and hosts[host].sessions[username] and hosts[host].sessions[username].roster;
		--if not roster then
		--	--roster = load_roster(username, host);
		--	return true; -- roster unchanged, no reason to save
		--end
	end
	if roster then
		local metadata = roster_metadata(roster);
		if metadata.version ~= true then
			metadata.version = (metadata.version or 0) + 1;
		end
		if metadata.broken then return nil, "Not saving broken roster" end
		if jid == nil then
			local roster_store = storagemanager.open(host, "roster", "keyval");
			return roster_store:set(username, roster);
		else
			local roster_store = storagemanager.open(host, "roster", "map");
			return roster_store:set_keys(username, { [false] = metadata, [jid] = roster[jid] or roster_store.remove });
		end
	end
	log("warn", "save_roster: user had no roster to save");
	return nil;
end

local function process_inbound_subscription_approval(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and item.ask then
		if item.subscription == "none" then
			item.subscription = "to";
		else -- subscription == from
			item.subscription = "both";
		end
		item.ask = nil;
		return save_roster(username, host, roster, jid);
	end
end

local is_contact_pending_out -- forward declaration

local function process_inbound_subscription_cancellation(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	local changed = nil;
	if is_contact_pending_out(username, host, jid) then
		item.ask = nil;
		changed = true;
	end
	if item then
		if item.subscription == "to" then
			item.subscription = "none";
			changed = true;
		elseif item.subscription == "both" then
			item.subscription = "from";
			changed = true;
		end
	end
	if changed then
		return save_roster(username, host, roster, jid);
	end
end

local is_contact_pending_in -- forward declaration

local function process_inbound_unsubscribe(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	local changed = nil;
	if is_contact_pending_in(username, host, jid) then
		roster[false].pending[jid] = nil;
		changed = true;
	end
	if item then
		if item.subscription == "from" then
			item.subscription = "none";
			changed = true;
		elseif item.subscription == "both" then
			item.subscription = "to";
			changed = true;
		end
	end
	if changed then
		return save_roster(username, host, roster, jid);
	end
end

local function _get_online_roster_subscription(jidA, jidB)
	local user = bare_sessions[jidA];
	local item = user and (user.roster[jidB] or { subscription = "none" });
	return item and item.subscription;
end
local function is_contact_subscribed(username, host, jid)
	do
		local selfjid = username.."@"..host;
		local user_subscription = _get_online_roster_subscription(selfjid, jid);
		if user_subscription then return (user_subscription == "both" or user_subscription == "from"); end
		local contact_subscription = _get_online_roster_subscription(jid, selfjid);
		if contact_subscription then return (contact_subscription == "both" or contact_subscription == "to"); end
	end
	local roster, err = load_roster(username, host);
	local item = roster[jid];
	return item and (item.subscription == "from" or item.subscription == "both"), err;
end
local function is_user_subscribed(username, host, jid)
	do
		local selfjid = username.."@"..host;
		local user_subscription = _get_online_roster_subscription(selfjid, jid);
		if user_subscription then return (user_subscription == "both" or user_subscription == "to"); end
		local contact_subscription = _get_online_roster_subscription(jid, selfjid);
		if contact_subscription then return (contact_subscription == "both" or contact_subscription == "from"); end
	end
	local roster, err = load_roster(username, host);
	local item = roster[jid];
	return item and (item.subscription == "to" or item.subscription == "both"), err;
end

function is_contact_pending_in(username, host, jid)
	local roster = load_roster(username, host);
	return roster[false].pending[jid] ~= nil;
end
local function set_contact_pending_in(username, host, jid, stanza)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "from" or item.subscription == "both") then
		return; -- false
	end
	roster[false].pending[jid] = st.is_stanza(stanza) and st.preserialize(stanza) or true;
	return save_roster(username, host, roster, jid);
end
function is_contact_pending_out(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	return item and item.ask;
end
local function is_contact_preapproved(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	return item and (item.approved == "true");
end
local function set_contact_pending_out(username, host, jid) -- subscribe
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.ask or item.subscription == "to" or item.subscription == "both") then
		return true;
	end
	if not item then
		item = {subscription = "none", groups = {}};
		roster[jid] = item;
	end
	item.ask = "subscribe";
	log("debug", "set_contact_pending_out: saving roster; set %s@%s.roster[%q].ask=subscribe", username, host, jid);
	return save_roster(username, host, roster, jid);
end
local function unsubscribe(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if not item then return false; end
	if (item.subscription == "from" or item.subscription == "none") and not item.ask then
		return true;
	end
	item.ask = nil;
	if item.subscription == "both" then
		item.subscription = "from";
	elseif item.subscription == "to" then
		item.subscription = "none";
	end
	return save_roster(username, host, roster, jid);
end
local function subscribed(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];

	if is_contact_pending_in(username, host, jid) then
		if not item then -- FIXME should roster item be auto-created?
			item = {subscription = "none", groups = {}};
			roster[jid] = item;
		end
		if item.subscription == "none" then
			item.subscription = "from";
		else -- subscription == to
			item.subscription = "both";
		end
		roster[false].pending[jid] = nil;
		return save_roster(username, host, roster, jid);
	elseif not item or item.subscription == "none" or item.subscription == "to" then
		-- Contact is not subscribed and has not sent a subscription request.
		-- We store a pre-approval as per RFC6121 3.4
		if not item then
			item = {subscription = "none", groups = {}};
			roster[jid] = item;
		end
		item.approved = "true";
		log("debug", "Storing preapproval for %s", jid);
		return save_roster(username, host, roster, jid);
	end
end
local function unsubscribed(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	local pending = is_contact_pending_in(username, host, jid);
	if pending then
		roster[false].pending[jid] = nil;
	end
	local is_subscribed;
	if item then
		if item.subscription == "from" then
			item.subscription = "none";
			is_subscribed = true;
		elseif item.subscription == "both" then
			item.subscription = "to";
			is_subscribed = true;
		end
	end
	local success = (pending or is_subscribed) and save_roster(username, host, roster, jid);
	return success, pending, is_subscribed;
end

local function process_outbound_subscription_request(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "none" or item.subscription == "from") then
		item.ask = "subscribe";
		return save_roster(username, host, roster, jid);
	end
end

--[[function process_outbound_subscription_approval(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "none" or item.subscription == "from" then
		item.ask = "subscribe";
		return save_roster(username, host, roster);
	end
end]]



return {
	add_to_roster = add_to_roster;
	remove_from_roster = remove_from_roster;
	roster_push = roster_push;
	load_roster = load_roster;
	save_roster = save_roster;
	process_inbound_subscription_approval = process_inbound_subscription_approval;
	process_inbound_subscription_cancellation = process_inbound_subscription_cancellation;
	process_inbound_unsubscribe = process_inbound_unsubscribe;
	is_contact_subscribed = is_contact_subscribed;
	is_user_subscribed = is_user_subscribed;
	is_contact_pending_in = is_contact_pending_in;
	set_contact_pending_in = set_contact_pending_in;
	is_contact_pending_out = is_contact_pending_out;
	set_contact_pending_out = set_contact_pending_out;
	is_contact_preapproved = is_contact_preapproved;
	unsubscribe = unsubscribe;
	subscribed = subscribed;
	unsubscribed = unsubscribed;
	process_outbound_subscription_request = process_outbound_subscription_request;
};
