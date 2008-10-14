
local mainlog = log;
local function log(type, message)
	mainlog(type, "rostermanager", message);
end

local setmetatable = setmetatable;
local format = string.format;
local loadfile, setfenv, pcall = loadfile, setfenv, pcall;

local hosts = hosts;

require "util.datamanager"

local datamanager = datamanager;

module "rostermanager"

--[[function getroster(username, host)
	return { 
			["mattj@localhost"] = true,
			["tobias@getjabber.ath.cx"] = true,
			["waqas@getjabber.ath.cx"] = true,
			["thorns@getjabber.ath.cx"] = true, 
			["idw@getjabber.ath.cx"] = true, 
		}
	--return datamanager.load(username, host, "roster") or {};
end]]

function add_to_roster(roster, jid, item)
	roster[jid] = item;
	-- TODO implement
end

function remove_from_roster(roster, jid)
	roster[jid] = nil;
	-- TODO implement
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
	error("Attempt to load roster for non-loaded user"); --return nil;
end

function save_roster(username, host)
	if hosts[host] and hosts[host].sessions[username] and hosts[host].sessions[username].roster then
		return datamanager.save(username, host, "roster", hosts[host].sessions[username].roster);
	end
	return nil;
end

return _M;