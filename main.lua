require "luarocks.require"

require "copas"
require "socket"
require "ssl"
require "lxp"

function log(type, area, message)
	print(type, area, message);
end

require "core.stanza_dispatch"
require "core.rostermanager"
require "core.offlinemessage"
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

users = {};
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

local ssl_ctx, msg = ssl.newcontext { mode = "server", protocol = "sslv23", key = "/home/matthew/ssl_cert/server.key",
    certificate = "/home/matthew/ssl_cert/server.crt", capath = "/etc/ssl/certs", verify = "none", }
        
if not ssl_ctx then error("Failed to initialise SSL/TLS support: "..tostring(msg)); end


function connect_host(host)
	hosts[host] = { type = "remote", sendbuffer = {} };
end

function handler(conn)
	local copas_receive, copas_send = copas.receive, copas.send;
	local reqdata, sktmsg;
	local session = { sendbuffer = { external = {} }, conn = conn, notopen = true, priority = 0 }


	-- Logging functions --

	local mainlog, log = log;
	do
		local conn_name = tostring(conn):match("%w+$");
		log = function (type, area, message) mainlog(type, conn_name, message); end
	end
	local print = function (...) log("info", "core", t_concatall({...}, "\t")); end
	session.log = log;

	--	--	--

	-- Send buffers --

	local sendbuffer = session.sendbuffer;
	local send = function (data) return t_insert(sendbuffer, tostring(data)); end;
	local send_to = 	function (to, stanza)
					local node, host, resource = jid.split(to);
					print("Routing stanza to "..to..":", node, host, resource);
					if not hosts[host] then
						print("   ...but host offline, establishing connection");
						connect_host(host);
						t_insert(hosts[host].sendbuffer, stanza); -- This will be sent when s2s connection succeeds					
					elseif hosts[host].connected then
						print("   ...putting in our external send buffer");
						t_insert(sendbuffer.external, { node = node, host = host, resource = resource, data = stanza});
						print("   ...there are now "..tostring(#sendbuffer.external).." stanzas in the external send buffer");
					end
				end
	session.send, session.send_to = send, send_to;

	--	--	--
	print("Client connected");
	conn = ssl.wrap(copas.wrap(conn), ssl_ctx);
	
	do
		local succ, msg
		conn:settimeout(15)
		while not succ do
			succ, msg = conn:dohandshake()
			if not succ then
				print("SSL: "..tostring(msg));
				if msg == 'wantread' then
					socket.select({conn}, nil)
				elseif msg == 'wantwrite' then
					socket.select(nil, {conn})
				else
					-- other error
				end
			end
		end
	end
	print("SSL handshake complete");
	-- XML parser initialisation --

	local parser;
	local stanza;
	
	local stanza_dispatch = init_stanza_dispatcher(session);

	local xml_handlers = {};
	
	do
		local ns_stack = { "" };
		local curr_ns = "";
		local curr_tag;
		function xml_handlers:StartElement(name, attr)
			curr_ns,name = name:match("^(.+):(%w+)$");
			print("Tag received:", name, tostring(curr_ns));
			if not stanza then
				if session.notopen then
					if name == "stream" then
						session.host = attr.to or error("Client failed to specify destination hostname");
			                        session.version = attr.version or 0;
			                        session.streamid = m_random(1000000, 99999999);
			                        print(session, session.host, "Client opened stream");
			                        send("<?xml version='1.0'?>");
			                        send(format("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' id='%s' from='%s' >", session.streamid, session.host));
			                        --send("<stream:features>");
			                        --send("<mechanism>PLAIN</mechanism>");
        			                --send [[<register xmlns="http://jabber.org/features/iq-register"/> ]]
        			                --send("</stream:features>");
						log("info", "core", "Stream opened successfully");
						session.notopen = nil;
						return;
					end
					error("Client failed to open stream successfully");
				end
				if name ~= "iq" and name ~= "presence" and name ~= "message" then
					error("Client sent invalid top-level stanza");
				end
				stanza = st.stanza(name, { to = attr.to, type = attr.type, id = attr.id, xmlns = curr_ns });
				curr_tag = stanza;
			else
				attr.xmlns = curr_ns;
				stanza:tag(name, attr);
			end
		end
		function xml_handlers:CharacterData(data)
			if data:match("%S") then
				stanza:text(data);
			end
		end
		function xml_handlers:EndElement(name)
			curr_ns,name = name:match("^(.+):(%w+)$");
			--print("<"..name.."/>", tostring(stanza), tostring(#stanza.last_add < 1), tostring(stanza.last_add[#stanza.last_add].name));
			if (not stanza) or #stanza.last_add < 0 or (#stanza.last_add > 0 and name ~= stanza.last_add[#stanza.last_add].name) then error("XML parse error in client stream"); end
			-- Complete stanza
			print(name, tostring(#stanza.last_add));
			if #stanza.last_add == 0 then
				stanza_dispatch(stanza);
				stanza = nil;
			else
				stanza:up();
			end
		end
--[[		function xml_handlers:StartNamespaceDecl(namespace)
			table.insert(ns_stack, namespace);
			curr_ns = namespace;
			log("debug", "parser", "Entering namespace "..tostring(curr_ns));
		end
		function xml_handlers:EndNamespaceDecl(namespace)
			table.remove(ns_stack);
			log("debug", "parser", "Leaving namespace "..tostring(curr_ns));
			curr_ns = ns_stack[#ns_stack];
			log("debug", "parser", "Entering namespace "..tostring(curr_ns));
		end
]]
	end
	parser = lxp.new(xml_handlers, ":");

	--	--	--

	-- Main loop --
	print "Receiving..."
	reqdata = copas_receive(conn, 1);
	print "Received"
	while reqdata do
		parser:parse(reqdata);
		if #sendbuffer.external > 0 then
			-- Stanzas queued to go to other places, from us
			-- ie. other local users, or remote hosts that weren't connected before
			print(#sendbuffer.external.." stanzas queued for other recipients, sending now...");
			for n, packet in pairs(sendbuffer.external) do
				if not hosts[packet.host] then
					connect_host(packet.host);
					t_insert(hosts[packet.host].sendbuffer, packet.data);
				elseif hosts[packet.host].type == "local" then
					print("   ...is to a local user")
					local destuser = hosts[packet.host].sessions[packet.node];
					if destuser and destuser.sessions then
						if not destuser.sessions[packet.resource] then
							local best_resource;
							for resource, session in pairs(destuser.sessions) do
								if not best_session then best_session = session;
								elseif session.priority >= best_session.priority and session.priority >= 0 then
									best_session = session;
								end
							end
							if not best_session then
								offlinemessage.new(packet.node, packet.host, packet.data);
							else
								print("resource '"..packet.resource.."' was not online, have chosen to send to '"..best_session.username.."@"..best_session.host.."/"..best_session.resource.."'");
								packet.resource = best_session.resource;
							end
						end
						if destuser.sessions[packet.resource] == session then
							log("warn", "core", "Attempt to send stanza to self, dropping...");
						else
							print("...sending...");
							copas_send(destuser.sessions[packet.resource].conn, tostring(packet.data));
							print("...sent")
						end
					elseif packet.data.name == "message" then
						print("   ...will be stored offline");
						offlinemessage.new(packet.node, packet.host, packet.data);
					elseif packet.data.name == "iq" then
						print("   ...is an iq");
						send(st.reply(packet.data)
							:tag("error", { type = "cancel" })
								:tag("service-unavailable", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" }));
					end
					print("   ...removing from send buffer");
					sendbuffer.external[n] = nil;
				end
			end
		end
		
		if #sendbuffer > 0 then 
			for n, data in ipairs(sendbuffer) do
				print "Sending..."
				copas_send(conn, data);
				print "Sent"
				sendbuffer[n] = nil;
			end
		end
		print "Receiving..."
		repeat
			reqdata, sktmsg = copas_receive(conn, 1);
			if sktmsg == 'wantread' then
				print("Received... wantread");
				--socket.select({conn}, nil)
				--print("Socket ready now...");
			elseif sktmsg then
				print("Received socket message:", sktmsg);
			end
		until reqdata or sktmsg == "closed";
		print("Received", tostring(reqdata));
	end
	log("info", "core", "Client disconnected, connection closed");
end

server = socket.bind("*", 5223)
assert(server, "Failed to bind to socket")
copas.addserver(server, handler)

copas.loop();
