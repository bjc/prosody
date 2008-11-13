pcall(require, "luarocks.require")

local server = require "net.server"
require "lxp"
require "socket"
require "ssl"

function log(type, area, message)
	print(type, area, message);
end

dofile "lxmppd.cfg"

-- Maps connections to sessions --
sessions = {};
hosts = {};

if config.hosts and #config.hosts > 0 then
	for _, host in pairs(config.hosts) do
		hosts[host] = {type = "local", connected = true, sessions = {}, host = host};
	end
else error("No hosts defined in the configuration file"); end

-- Load and initialise core modules --

require "util.import"
require "core.xmlhandlers"
require "core.rostermanager"
require "core.offlinemessage"
require "core.modulemanager"
require "core.usermanager"
require "core.sessionmanager"
require "core.stanza_router"

pcall(require, "remdebug.engine");
if remdebug then remdebug.engine.start() end

local start = require "net.connlisteners".start;
require "util.stanza"
require "util.jid"

------------------------------------------------------------------------

-- Initialise modules
if config.modules and #config.modules > 0 then
	for _, module in pairs(config.modules) do
		modulemanager.load(module);
	end
else error("No modules enabled in the configuration file"); end

-- setup error handling
setmetatable(_G, { __index = function (t, k) print("WARNING: ATTEMPT TO READ A NIL GLOBAL!!!", k); error("Attempt to read a non-existent global. Naughty boy.", 2); end, __newindex = function (t, k, v) print("ATTEMPT TO SET A GLOBAL!!!!", tostring(k).." = "..tostring(v)); error("Attempt to set a global. Naughty boy.", 2); end }) --]][][[]][];

local protected_handler = function (conn, data, err) local success, ret = pcall(handler, conn, data, err); if not success then print("ERROR on "..tostring(conn)..": "..ret); conn:close(); end end;
local protected_disconnect = function (conn, err) local success, ret = pcall(disconnect, conn, err); if not success then print("ERROR on "..tostring(conn).." disconnect: "..ret); conn:close(); end end;

-- start listening on sockets
start("xmppclient", { ssl = config.ssl_ctx })
start("xmppserver", { ssl = config.ssl_ctx })

server.loop();
