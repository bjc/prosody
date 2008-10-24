require "luarocks.require"

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
 
-- Load and initialise core modules --
 
require "util.import"
require "core.stanza_dispatch"
require "core.xmlhandlers"
require "core.rostermanager"
require "core.offlinemessage"
require "core.modulemanager"
require "core.usermanager"
require "core.sessionmanager"
require "core.stanza_router"

local start = require "net.connlisteners".start;
require "util.stanza"
require "util.jid"

------------------------------------------------------------------------
 
-- Locals for faster access --
local t_insert = table.insert;
local t_concat = table.concat;
local t_concatall = function (t, sep) local tt = {}; for _, s in ipairs(t) do t_insert(tt, tostring(s)); end return t_concat(tt, sep); end
local m_random = math.random;
local format = string.format;
local sm_new_session, sm_destroy_session = sessionmanager.new_session, sessionmanager.destroy_session; --import("core.sessionmanager", "new_session", "destroy_session");
local st = stanza;
------------------------------

local hosts, sessions = hosts, sessions;

-- Initialise modules
modulemanager.loadall();

setmetatable(_G, { __index = function (t, k) print("WARNING: ATTEMPT TO READ A NIL GLOBAL!!!", k); error("Attempt to read a non-existent global. Naughty boy.", 2); end, __newindex = function (t, k, v) print("ATTEMPT TO SET A GLOBAL!!!!", tostring(k).." = "..tostring(v)); error("Attempt to set a global. Naughty boy.", 2); end }) --]][][[]][];


local protected_handler = function (conn, data, err) local success, ret = pcall(handler, conn, data, err); if not success then print("ERROR on "..tostring(conn)..": "..ret); conn:close(); end end;
local protected_disconnect = function (conn, err) local success, ret = pcall(disconnect, conn, err); if not success then print("ERROR on "..tostring(conn).." disconnect: "..ret); conn:close(); end end;

start("xmppclient", { ssl = ssl_ctx })
start("xmppserver", { ssl = ssl_ctx })

server.loop();
