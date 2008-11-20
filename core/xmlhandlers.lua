
require "util.stanza"

local st = stanza;
local tostring = tostring;
local pairs = pairs;
local ipairs = ipairs;
local type = type;
local print = print;
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

local ns_prefixes = {
						["http://www.w3.org/XML/1998/namespace"] = "xml";
				}

function init_xmlhandlers(session, stream_callbacks)
		local ns_stack = { "" };
		local curr_ns = "";
		local curr_tag;
		local chardata = {};
		local xml_handlers = {};
		local log = session.log or default_log;
		--local print = function (...) log("info", "xmlhandlers", t_concatall({...}, "\t")); end
		
		local send = session.send;
		
		local cb_streamopened = stream_callbacks.streamopened;
		local cb_streamclosed = stream_callbacks.streamclosed;
		
		local stanza
		function xml_handlers:StartElement(name, attr)
			if stanza and #chardata > 0 then
				-- We have some character data in the buffer
				stanza:text(t_concat(chardata));
				chardata = {};
			end
			curr_ns,name = name:match("^(.+)|([%w%-]+)$");
			if curr_ns ~= "jabber:server" then
				attr.xmlns = curr_ns;
			end
			
			-- FIXME !!!!!
			for i, k in ipairs(attr) do
				if type(k) == "string" then
					local ns, nm = k:match("^([^|]+)|?([^|]-)$")
					if ns and nm then
						ns = ns_prefixes[ns]; 
						if ns then 
							attr[ns..":"..nm] = attr[k];
							attr[i] = ns..":"..nm;
							attr[k] = nil;
						end
					end
				end
			end
			
			if not stanza then --if we are not currently inside a stanza
				if session.notopen then
					if name == "stream" then
						if cb_streamopened then
							cb_streamopened(session, attr);
						end
						return;
					end
					error("Client failed to open stream successfully");
				end
				if curr_ns == "jabber:client" and name ~= "iq" and name ~= "presence" and name ~= "message" then
					error("Client sent invalid top-level stanza");
				end
				
				stanza = st.stanza(name, attr);
				curr_tag = stanza;
			else -- we are inside a stanza, so add a tag
				attr.xmlns = nil;
				if curr_ns ~= "jabber:server" and curr_ns ~= "jabber:client" then
					attr.xmlns = curr_ns;
				end
				stanza:tag(name, attr);
			end
		end
		function xml_handlers:CharacterData(data)
			if stanza then
				t_insert(chardata, data);
			end
		end
		function xml_handlers:EndElement(name)
			curr_ns,name = name:match("^(.+)|([%w%-]+)$");
			if (not stanza) or (#stanza.last_add > 0 and name ~= stanza.last_add[#stanza.last_add].name) then 
				if name == "stream" then
					log("debug", "Stream closed");
					if cb_streamclosed then
						cb_streamclosed(session);
					end
					return;
				elseif name == "error" then
					error("Stream error: "..tostring(name)..": "..tostring(stanza));
				else
					error("XML parse error in client stream with element: "..name);
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
