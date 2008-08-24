require "luarocks.require"

server = require "server"
require "socket"
require "ssl"
require "lxp"

function log(type, area, message)
	print(type, area, message);
end

require "core.stanza_dispatch"
local init_xmlhandlers = require "core.xmlhandlers"
require "core.rostermanager"
require "core.offlinemessage"
require "core.usermanager"
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

sessions = {};
hosts = 	{ 
			["localhost"] = 	{
							type = "local";
							connected = true;
							sessions = {};
						};
			["getjabber.ath.cx"] = 	{
							type = "local";
							connected = true;
							sessions = {};
						};
		}

local hosts, users = hosts, users;

--local ssl_ctx, msg = ssl.newcontext { mode = "server", protocol = "sslv23", key = "/home/matthew/ssl_cert/server.key",
--    certificate = "/home/matthew/ssl_cert/server.crt", capath = "/etc/ssl/certs", verify = "none", }
--        
--if not ssl_ctx then error("Failed to initialise SSL/TLS support: "..tostring(msg)); end


local ssl_ctx = { mode = "server", protocol = "sslv23", key = "/home/matthew/ssl_cert/server.key",
    certificate = "/home/matthew/ssl_cert/server.crt", capath = "/etc/ssl/certs", verify = "none", }


function connect_host(host)
	hosts[host] = { type = "remote", sendbuffer = {} };
end

local function send_to(session, to, stanza)
	local node, host, resource = jid.split(to);
	if not hosts[host] then
		-- s2s
	elseif hosts[host].type == "local" then
		print("   ...is to a local user")
		local destuser = hosts[host].sessions[node];
		if destuser and destuser.sessions then
			if not destuser.sessions[resource] then
				local best_session;
				for resource, session in pairs(destuser.sessions) do
					if not best_session then best_session = session;
					elseif session.priority >= best_session.priority and session.priority >= 0 then
						best_session = session;
					end
				end
				if not best_session then
					offlinemessage.new(node, host, stanza);
				else
					print("resource '"..resource.."' was not online, have chosen to send to '"..best_session.username.."@"..best_session.host.."/"..best_session.resource.."'");
					resource = best_session.resource;
				end
			end
			if destuser.sessions[resource] == session then
				log("warn", "core", "Attempt to send stanza to self, dropping...");
			else
				print("...sending...", tostring(stanza));
				--destuser.sessions[resource].conn.write(tostring(data));
				print("   to conn ", destuser.sessions[resource].conn);
				destuser.sessions[resource].conn.write(tostring(stanza));
				print("...sent")
			end
		elseif stanza.name == "message" then
			print("   ...will be stored offline");
			offlinemessage.new(node, host, stanza);
		elseif stanza.name == "iq" then
			print("   ...is an iq");
			session.send(st.reply(stanza)
				:tag("error", { type = "cancel" })
					:tag("service-unavailable", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" }));
		end
		print("   ...done routing");
	end
end

function handler(conn, data, err)
	local session = sessions[conn];

	if not session then
		sessions[conn] = { conn = conn, notopen = true, priority = 0 };
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

		--	--	--

		-- Send buffers --

		local send = function (data) print("Sending...", tostring(data)); conn.write(tostring(data)); end;
		session.send, session.send_to = send, send_to;

		print("Client connected");
		
		session.stanza_dispatch = init_stanza_dispatcher(session);
		session.xml_handlers = init_xmlhandlers(session);
		session.parser = lxp.new(session.xml_handlers, ":");
			
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
		session.parser:parse(data);
	end
	
	--log("info", "core", "Client disconnected, connection closed");
end

function disconnect(conn, err)
	sessions[conn].disconnect(err);
end

print("ssl_ctx:", type(ssl_ctx));

setmetatable(_G, { __index = function (t, k) print("WARNING: ATTEMPT TO READ A NIL GLOBAL!!!", k); error("Attempt to read a non-existent global. Naughty boy.", 2); end, __newindex = function (t, k, v) print("ATTEMPT TO SET A GLOBAL!!!!", tostring(k).." = "..tostring(v)); error("Attempt to set a global. Naughty boy.", 2); end }) --]][][[]][];


local protected_handler = function (...) local success, ret = pcall(handler, ...); if not success then print("ERROR on "..tostring((select(1, ...)))..": "..ret); end end;
local protected_disconnect = function (...) local success, ret = pcall(disconnect, ...); if not success then print("ERROR on "..tostring((select(1, ...))).." disconnect: "..ret); end end;

print( server.add( { listener = protected_handler, disconnect = protected_disconnect }, 5222, "*", 1, nil ) )    -- server.add will send a status message
print( server.add( { listener = protected_handler, disconnect = protected_disconnect }, 5223, "*", 1, ssl_ctx ) )    -- server.add will send a status message

server.loop();
