
local mainlog = log;
local function log(type, message)
	mainlog(type, "rostermanager", message);
end

local setmetatable = setmetatable;
local format = string.format;
local loadfile, setfenv, pcall = loadfile, setfenv, pcall;
local pairs, ipairs = pairs, ipairs;

local hosts = hosts;

require "util.datamanager"

local datamanager = datamanager;
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
	if hosts[host] and hosts[host].sessions[username] and hosts[host].sessions[username].roster then
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
		stanza:up();
		stanza:up();
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
	if hosts[host] and hosts[host].sessions[username] then
		local roster = hosts[host].sessions[username].roster;
		if not roster then
			roster = datamanager.load(username, host, "roster") or {};
			hosts[host].sessions[username].roster = roster;
		end
		return roster;
	end
	-- Attempt to load roster for non-loaded user
	return datamanager.load(username, host, "roster") or {};
end

function save_roster(username, host)
	if hosts[host] and hosts[host].sessions[username] and hosts[host].sessions[username].roster then
		return datamanager.store(username, host, "roster", hosts[host].sessions[username].roster);
	end
	return nil;
end

function process_inbound_subscription_approval(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and item.ask and (item.subscription == "none" or item.subscription == "from") then
		if item.subscription == "none" then
			item.subscription = "to";
		else
			item.subscription = "both";
		end
		item.ask = nil;
		return datamanager.store(username, host, "roster", roster);
	end
end

function process_inbound_subscription_cancellation(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "to" or item.subscription == "both") then
		if item.subscription == "to" then
			item.subscription = "none";
		else
			item.subscription = "from";
		end
		-- FIXME do we need to item.ask = nil;?
		return datamanager.store(username, host, "roster", roster);
	end
end

function process_inbound_unsubscribe(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "from" or item.subscription == "both") then
		if item.subscription == "from" then
			item.subscription = "none";
		else
			item.subscription = "to";
		end
		item.ask = nil;
		return datamanager.store(username, host, "roster", roster);
	end
end

return _M;