
require "util.stanza"

local st = stanza;
local tostring = tostring;
local format = string.format;
local m_random = math.random;
local t_insert = table.insert;
local t_remove = table.remove;
local t_concat = table.concat;
local t_concatall = function (t, sep) local tt = {}; for _, s in ipairs(t) do t_insert(tt, tostring(s)); end return t_concat(tt, sep); end
local sm_destroy_session = import("core.sessionmanager", "destroy_session");

local default_log = require "util.logger".init("xmlhandlers");

local error = error;

module "xmlhandlers"

function init_xmlhandlers(session, streamopened)
		local ns_stack = { "" };
		local curr_ns = "";
		local curr_tag;
		local chardata = {};
		local xml_handlers = {};
		local log = session.log or default_log;
		local print = function (...) log("info", "xmlhandlers", t_concatall({...}, "\t")); end
		
		local send = session.send;
		
		local stanza
		function xml_handlers:StartElement(name, attr)
			if stanza and #chardata > 0 then
				-- We have some character data in the buffer
				stanza:text(t_concat(chardata));
				chardata = {};
			end
			log("debug", "Start element: %s", tostring(name));
			curr_ns,name = name:match("^(.+):([%w%-]+)$");
			attr.xmlns = curr_ns;
			
			if not stanza then --if we are not currently inside a stanza
				if session.notopen then
					if name == "stream" then
						streamopened(session, attr);
						return;
					end
					error("Client failed to open stream successfully");
				end
				if curr_ns == "jabber:client" and name ~= "iq" and name ~= "presence" and name ~= "message" then
					error("Client sent invalid top-level stanza");
				end
				
				stanza = st.stanza(name, attr); --{ to = attr.to, type = attr.type, id = attr.id, xmlns = curr_ns });
				curr_tag = stanza;
			else -- we are inside a stanza, so add a tag
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
			curr_ns,name = name:match("^(.+):([%w%-]+)$");
			if (not stanza) or #stanza.last_add < 0 or (#stanza.last_add > 0 and name ~= stanza.last_add[#stanza.last_add].name) then 
				if name == "stream" then
					log("debug", "Stream closed");
					sm_destroy_session(session);
					return;
				elseif name == "error" then
					error("Stream error: "..tostring(name)..": "..tostring(stanza));
				else
					error("XML parse error in client stream");
				end
			end
			if stanza and #chardata > 0 then
				-- We have some character data in the buffer
				stanza:text(t_concat(chardata));
				chardata = {};
			end
			-- Complete stanza
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
