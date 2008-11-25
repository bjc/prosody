pcall(require, "luarocks.require")

local server = require "net.server"
local config = require "core.configmanager"

require "util.dependencies"

log = require "util.logger".init("general");

do
	-- TODO: Check for other formats when we add support for them
	-- Use lfs? Make a new conf/ dir?
	local ok, err = config.load("lxmppd.cfg.lua");
	if not ok then
		log("error", "Couldn't load config file: %s", err);
		log("info", "Falling back to old config file format...")
		ok, err = pcall(dofile, "lxmppd.cfg");
		if not ok then
			log("error", "Old config format loading failed too: %s", err);
		else
			for _, host in ipairs(_G.config.hosts) do
				config.set(host, "core", "defined", true);
			end
			
			config.set("*", "core", "modules_enabled", _G.config.modules);
			config.set("*", "core", "ssl", _G.config.ssl_ctx);
		end
	end
end

-- Maps connections to sessions --
sessions = {};
hosts = {};

local defined_hosts = config.getconfig();

for host, host_config in pairs(defined_hosts) do
	if host ~= "*" and (host_config.core.enabled == nil or host_config.core.enabled) then
		hosts[host] = {type = "local", connected = true, sessions = {}, host = host, s2sout = {} };
	end
end

-- Load and initialise core modules --

require "util.import"
require "core.xmlhandlers"
require "core.rostermanager"
require "core.offlinemessage"
require "core.modulemanager"
require "core.usermanager"
require "core.sessionmanager"
require "core.stanza_router"

--[[
pcall(require, "remdebug.engine");
if remdebug then remdebug.engine.start() end
]]

local start = require "net.connlisteners".start;
require "util.stanza"
require "util.jid"

------------------------------------------------------------------------

-- Initialise modules
local modules_enabled = config.get("*", "core", "modules_enabled");
if modules_enabled then
	for _, module in pairs(modules_enabled) do
		modulemanager.load(module);
	end
end

-- setup error handling
setmetatable(_G, { __index = function (t, k) print("WARNING: ATTEMPT TO READ A NIL GLOBAL!!!", k); error("Attempt to read a non-existent global. Naughty boy.", 2); end, __newindex = function (t, k, v) print("ATTEMPT TO SET A GLOBAL!!!!", tostring(k).." = "..tostring(v)); error("Attempt to set a global. Naughty boy.", 2); end }) --]][][[]][];

local protected_handler = function (conn, data, err) local success, ret = pcall(handler, conn, data, err); if not success then print("ERROR on "..tostring(conn)..": "..ret); conn:close(); end end;
local protected_disconnect = function (conn, err) local success, ret = pcall(disconnect, conn, err); if not success then print("ERROR on "..tostring(conn).." disconnect: "..ret); conn:close(); end end;


local global_ssl_ctx = config.get("*", "core", "ssl");
if global_ssl_ctx then
	local default_ssl_ctx = { mode = "server", protocol = "sslv23", capath = "/etc/ssl/certs", verify = "none"; };
	setmetatable(global_ssl_ctx, { __index = default_ssl_ctx });
end

-- start listening on sockets
start("xmppclient", { ssl = global_ssl_ctx })
start("xmppserver", { ssl = global_ssl_ctx })

if config.get("*", "core", "console_enabled") then
	start("console")
end

modulemanager.fire_event("server-started");

server.loop();
