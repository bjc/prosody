

local log = require "util.logger".init("rostermanager");

local setmetatable = setmetatable;
local format = string.format;
local loadfile, setfenv, pcall = loadfile, setfenv, pcall;
local pairs, ipairs = pairs, ipairs;

local hosts = hosts;

local datamanager = require "util.datamanager"
local st = require "util.stanza";

module "rostermanager"

function add_to_roster(session, jid, item)
	if session.roster then
		local old_item = session.roster[jid];
		session.roster[jid] = item;
		if save_roster(session.username, session.host) then
			return true;
		else
			session.roster[jid] = old_item;
			return nil, "wait", "internal-server-error", "Unable to save roster";
		end
	else
		return nil, "auth", "not-authorized", "Session's roster not loaded";
	end
end

function remove_from_roster(session, jid)
	if session.roster then
		local old_item = session.roster[jid];
		session.roster[jid] = nil;
		if save_roster(session.username, session.host) then
			return true;
		else
			session.roster[jid] = old_item;
			return nil, "wait", "internal-server-error", "Unable to save roster";
		end
	else
		return nil, "auth", "not-authorized", "Session's roster not loaded";
	end
end

function roster_push(username, host, jid)
	if jid ~= "pending" and hosts[host] and hosts[host].sessions[username] and hosts[host].sessions[username].roster then
		local item = hosts[host].sessions[username].roster[jid];
		local stanza = st.iq({type="set"});
		stanza:tag("query", {xmlns = "jabber:iq:roster"});
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
				-- FIXME do we need to set stanza.attr.to?
				session.send(stanza);
			end
		end
	end
end

function load_roster(username, host)
	log("debug", "load_roster: asked for: "..username.."@"..host);
	if hosts[host] and hosts[host].sessions[username] then
		local roster = hosts[host].sessions[username].roster;
		if not roster then
			log("debug", "load_roster: loading for new user: "..username.."@"..host);
			roster = datamanager.load(username, host, "roster") or {};
			hosts[host].sessions[username].roster = roster;
		end
		return roster;
	end
	-- Attempt to load roster for non-loaded user
	log("debug", "load_roster: loading for offline user: "..username.."@"..host);
	return datamanager.load(username, host, "roster") or {};
end

function save_roster(username, host)
	log("debug", "save_roster: saving roster for "..username.."@"..host);
	if hosts[host] and hosts[host].sessions[username] and hosts[host].sessions[username].roster then
		return datamanager.store(username, host, "roster", hosts[host].sessions[username].roster);
	end
	return nil;
end

function process_inbound_subscription_approval(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and item.ask then
		if item.subscription == "none" then
			item.subscription = "to";
		else -- subscription == from
			item.subscription = "both";
		end
		item.ask = nil;
		return datamanager.store(username, host, "roster", roster);
	end
end

function process_inbound_subscription_cancellation(username, host, jid)
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
		return datamanager.store(username, host, "roster", roster);
	end
end

function process_inbound_unsubscribe(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	local changed = nil;
	if is_contact_pending_in(username, host, jid) then
		roster.pending[jid] = nil; -- TODO maybe delete roster.pending if empty?
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
		return datamanager.store(username, host, "roster", roster);
	end
end

function is_contact_subscribed(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	return item and (item.subscription == "from" or item.subscription == "both");
end

function is_contact_pending_in(username, host, jid)
	local roster = load_roster(username, host);
	return roster.pending and roster.pending[jid];
end
function set_contact_pending_in(username, host, jid, pending)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "from" or item.subscription == "both") then
		return; -- false
	end
	if not roster.pending then roster.pending = {}; end
	roster.pending[jid] = true;
	return datamanager.store(username, host, "roster", roster);
end
function is_contact_pending_out(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	return item and item.ask;
end
function set_contact_pending_out(username, host, jid) -- subscribe
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
	log("debug", "set_contact_pending_out: saving roster; set "..username.."@"..host..".roster["..jid.."].ask=subscribe");
	return datamanager.store(username, host, "roster", roster);
end
function unsubscribe(username, host, jid)
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
	return datamanager.store(username, host, "roster", roster);
end
function subscribed(username, host, jid)
	if is_contact_pending_in(username, host, jid) then
		local roster = load_roster(username, host);
		local item = roster[jid];
		if item.subscription == "none" then
			item.subscription = "from";
		else -- subscription == to
			item.subscription = "both";
		end
		roster.pending[jid] = nil;
		-- TODO maybe remove roster.pending if empty
		return datamanager.store(username, host, "roster", roster);
	end -- TODO else implement optional feature pre-approval (ask = subscribed)
end
function unsubscribed(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	local pending = is_contact_pending_in(username, host, jid);
	local changed = nil;
	if is_contact_pending_in(username, host, jid) then
		roster.pending[jid] = nil; -- TODO maybe delete roster.pending if empty?
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
		return datamanager.store(username, host, "roster", roster);
	end
end

function process_outbound_subscription_request(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "none" or item.subscription == "from") then
		item.ask = "subscribe";
		return datamanager.store(username, host, "roster", roster);
	end
end

--[[function process_outbound_subscription_approval(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "none" or item.subscription == "from" then
		item.ask = "subscribe";
		return datamanager.store(username, host, "roster", roster);
	end
end]]



return _M;