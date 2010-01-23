-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



require "util.stanza"

local st = stanza;
local tostring = tostring;
local pairs = pairs;
local ipairs = ipairs;
local t_insert = table.insert;
local t_concat = table.concat;

local default_log = require "util.logger".init("xmlhandlers");

local error = error;

module "xmlhandlers"

local ns_prefixes = {
	["http://www.w3.org/XML/1998/namespace"] = "xml";
};

local xmlns_streams = "http://etherx.jabber.org/streams";

local ns_separator = "\1";
local ns_pattern = "^([^"..ns_separator.."]*)"..ns_separator.."?(.*)$";

function init_xmlhandlers(session, stream_callbacks)
	local ns_stack = { "" };
	local curr_tag;
	local chardata = {};
	local xml_handlers = {};
	local log = session.log or default_log;
	
	local cb_streamopened = stream_callbacks.streamopened;
	local cb_streamclosed = stream_callbacks.streamclosed;
	local cb_error = stream_callbacks.error or function(session, e) error("XML stream error: "..tostring(e)); end;
	local cb_handlestanza = stream_callbacks.handlestanza;
	
	local stream_ns = stream_callbacks.stream_ns or xmlns_streams;
	local stream_tag = stream_ns..ns_separator..(stream_callbacks.stream_tag or "stream");
	local stream_error_tag = stream_ns..ns_separator..(stream_callbacks.error_tag or "error");
	
	local stream_default_ns = stream_callbacks.default_ns;
	
	local stanza;
	function xml_handlers:StartElement(tagname, attr)
		if stanza and #chardata > 0 then
			-- We have some character data in the buffer
			stanza:text(t_concat(chardata));
			chardata = {};
		end
		local curr_ns,name = tagname:match(ns_pattern);
		if name == "" then
			curr_ns, name = "", curr_ns;
		end

		if curr_ns ~= stream_default_ns then
			attr.xmlns = curr_ns;
		end
		
		-- FIXME !!!!!
		for i=1,#attr do
			local k = attr[i];
			attr[i] = nil;
			local ns, nm = k:match(ns_pattern);
			if nm ~= "" then
				ns = ns_prefixes[ns]; 
				if ns then 
					attr[ns..":"..nm] = attr[k];
					attr[k] = nil;
				end
			end
		end
		
		if not stanza then --if we are not currently inside a stanza
			if session.notopen then
				if tagname == stream_tag then
					if cb_streamopened then
						cb_streamopened(session, attr);
					end
				else
					-- Garbage before stream?
					cb_error(session, "no-stream");
				end
				return;
			end
			if curr_ns == "jabber:client" and name ~= "iq" and name ~= "presence" and name ~= "message" then
				cb_error(session, "invalid-top-level-element");
			end
			
			stanza = st.stanza(name, attr);
			curr_tag = stanza;
		else -- we are inside a stanza, so add a tag
			attr.xmlns = nil;
			if curr_ns ~= stream_default_ns then
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
	function xml_handlers:EndElement(tagname)
		local curr_ns,name = tagname:match(ns_pattern);
		if name == "" then
			curr_ns, name = "", curr_ns;
		end
		if not stanza then
			if tagname == stream_tag then
				if cb_streamclosed then
					cb_streamclosed(session);
				end
			else
				cb_error(session, "parse-error", "unexpected-element-close", name);
			end
			stanza, chardata = nil, {};
			return;
		end
		if #chardata > 0 then
			-- We have some character data in the buffer
			stanza:text(t_concat(chardata));
			chardata = {};
		end
		-- Complete stanza
		if #stanza.last_add == 0 then
			if tagname ~= stream_error_tag then
				cb_handlestanza(session, stanza);
			else
				cb_error(session, "stream-error", stanza);
			end
			stanza = nil;
		else
			stanza:up();
		end
	end
	return xml_handlers;
end

return init_xmlhandlers;
