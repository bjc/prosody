
require "util.stanza"

local st = stanza;
local tostring = tostring;
local format = string.format;
local m_random = math.random;
local t_insert = table.insert;
local t_remove = table.remove;
local t_concat = table.concat;
local t_concatall = function (t, sep) local tt = {}; for _, s in ipairs(t) do t_insert(tt, tostring(s)); end return t_concat(tt, sep); end

local error = error;

module "xmlhandlers"

function init_xmlhandlers(session)
		local ns_stack = { "" };
		local curr_ns = "";
		local curr_tag;
		local chardata = {};
		local xml_handlers = {};
		local log = session.log;
		local print = function (...) log("info", "xmlhandlers", t_concatall({...}, "\t")); end
		
		local send = session.send;
		
		local stanza
		function xml_handlers:StartElement(name, attr)
			if stanza and #chardata > 0 then
				stanza:text(t_concat(chardata));
				print("Char data:", t_concat(chardata));
				chardata = {};
			end
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
			                        send(format("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' id='%s' from='%s' version='1.0'>", session.streamid, session.host));
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
			if stanza then
				t_insert(chardata, data);
			end
		end
		function xml_handlers:EndElement(name)
			curr_ns,name = name:match("^(.+):(%w+)$");
			--print("<"..name.."/>", tostring(stanza), tostring(#stanza.last_add < 1), tostring(stanza.last_add[#stanza.last_add].name));
			if (not stanza) or #stanza.last_add < 0 or (#stanza.last_add > 0 and name ~= stanza.last_add[#stanza.last_add].name) then error("XML parse error in client stream"); end
			if stanza and #chardata > 0 then
				stanza:text(t_concat(chardata));
				print("Char data:", t_concat(chardata));
				chardata = {};
			end
			-- Complete stanza
			print(name, tostring(#stanza.last_add));
			if #stanza.last_add == 0 then
				session.stanza_dispatch(stanza);
				stanza = nil;
			else
				stanza:up();
			end
		end
	return xml_handlers;
end

return init_xmlhandlers;
