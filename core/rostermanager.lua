
local mainlog = log;
local function log(type, message)
	mainlog(type, "rostermanager", message);
end

local setmetatable = setmetatable;
local format = string.format;
local loadfile, setfenv, pcall = loadfile, setfenv, pcall;

require "util.datamanager"

local datamanager = datamanager;

module "rostermanager"

function getroster(username, host)
	return datamanager.load(username, host, "roster") or {};
end
