require "luarocks.require"

server = require "net.server"
require "socket"
require "ssl"
require "lxp"

function log(type, area, message)
	print(type, area, message);
end

dofile "lxmppd.cfg"
 
sessions = {};
 
require "core.stanza_dispatch"
require "core.xmlhandlers"
require "core.rostermanager"
require "core.offlinemessage"
require "core.modulemanager"
require "core.usermanager"
require "core.sessionmanager"
require "core.stanza_router"
require "net.connhandlers"
require "util.stanza"
require "util.jid"
 
-- Locals for faster access --
local t_insert = table.insert;
local t_concat = table.concat;
local t_concatall = function (t, sep) local tt = {}; for _, s in ipairs(t) do t_insert(tt, tostring(s)); end return t_concat(tt, sep); end
local m_random = math.random;
local format = string.format;
local st = stanza;
------------------------------



local hosts, users = hosts, users;

function connect_host(host)
	hosts[host] = { type = "remote", sendbuffer = {} };
end

function handler(conn, data, err)
	local session = sessions[conn];

	if not session then
		sessions[conn] = sessionmanager.new_session(conn);
		session = sessions[conn];

		-- Logging functions --

		local mainlog, log = log;
		do
			local conn_name = tostring(conn):match("%w+$");
			log = function (type, area, message) mainlog(type, conn_name, message); end
			--log = function () end
		end
		local print = function (...) log("info", "core", t_concatall({...}, "\t")); end
		session.log = log;

		print("Client connected");
		
		session.stanza_dispatch = function (stanza) return core_process_stanza(session, stanza); end
		
		session.connhandler = connhandlers.new("xmpp-client", session);
			
		function session.disconnect(err)
			if session.last_presence and session.last_presence.attr.type ~= "unavailable" then
				local pres = st.presence{ type = "unavailable" };
				if err == "closed" then err = "connection closed"; end
				pres:tag("status"):text("Disconnected: "..err);
				session.stanza_dispatch(pres);
			end
			if session.username then
				hosts[session.host].sessions[session.username] = nil;
			end
			session = nil;
			print("Disconnected: "..err);
			collectgarbage("collect");
		end
	end
	if data then
		session.connhandler:data(data);
	end
	
	--log("info", "core", "Client disconnected, connection closed");
end

function disconnect(conn, err)
	sessions[conn].disconnect(err);
	sessions[conn] = nil;
end

modulemanager.loadall();

setmetatable(_G, { __index = function (t, k) print("WARNING: ATTEMPT TO READ A NIL GLOBAL!!!", k); error("Attempt to read a non-existent global. Naughty boy.", 2); end, __newindex = function (t, k, v) print("ATTEMPT TO SET A GLOBAL!!!!", tostring(k).." = "..tostring(v)); error("Attempt to set a global. Naughty boy.", 2); end }) --]][][[]][];


local protected_handler = function (conn, data, err) local success, ret = pcall(handler, conn, data, err); if not success then print("ERROR on "..tostring(conn)..": "..ret); conn:close(); end end;
local protected_disconnect = function (conn, err) local success, ret = pcall(disconnect, conn, err); if not success then print("ERROR on "..tostring(conn).." disconnect: "..ret); conn:close(); end end;

server.add( { listener = protected_handler, disconnect = protected_disconnect }, 5222, "*", 1, nil ) -- server.add will send a status message
server.add( { listener = protected_handler, disconnect = protected_disconnect }, 5223, "*", 1, ssl_ctx ) -- server.add will send a status message

server.loop();
