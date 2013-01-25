-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local lxp = require "lxp";
local st = require "util.stanza";
local stanza_mt = st.stanza_mt;

local error = error;
local tostring = tostring;
local t_insert = table.insert;
local t_concat = table.concat;
local t_remove = table.remove;
local setmetatable = setmetatable;

-- COMPAT: w/LuaExpat 1.1.0
local lxp_supports_doctype = pcall(lxp.new, { StartDoctypeDecl = false });

module "xmppstream"

local new_parser = lxp.new;

local xml_namespace = {
	["http://www.w3.org/XML/1998/namespace\1lang"] = "xml:lang";
	["http://www.w3.org/XML/1998/namespace\1space"] = "xml:space";
	["http://www.w3.org/XML/1998/namespace\1base"] = "xml:base";
	["http://www.w3.org/XML/1998/namespace\1id"] = "xml:id";
};

local xmlns_streams = "http://etherx.jabber.org/streams";

local ns_separator = "\1";
local ns_pattern = "^([^"..ns_separator.."]*)"..ns_separator.."?(.*)$";

_M.ns_separator = ns_separator;
_M.ns_pattern = ns_pattern;

function new_sax_handlers(session, stream_callbacks)
	local xml_handlers = {};
	
	local cb_streamopened = stream_callbacks.streamopened;
	local cb_streamclosed = stream_callbacks.streamclosed;
	local cb_error = stream_callbacks.error or function(session, e, stanza) error("XML stream error: "..tostring(e)..(stanza and ": "..tostring(stanza) or ""),2); end;
	local cb_handlestanza = stream_callbacks.handlestanza;
	
	local stream_ns = stream_callbacks.stream_ns or xmlns_streams;
	local stream_tag = stream_callbacks.stream_tag or "stream";
	if stream_ns ~= "" then
		stream_tag = stream_ns..ns_separator..stream_tag;
	end
	local stream_error_tag = stream_ns..ns_separator..(stream_callbacks.error_tag or "error");
	
	local stream_default_ns = stream_callbacks.default_ns;
	
	local stack = {};
	local chardata, stanza = {};
	local non_streamns_depth = 0;
	function xml_handlers:StartElement(tagname, attr)
		if stanza and #chardata > 0 then
			-- We have some character data in the buffer
			t_insert(stanza, t_concat(chardata));
			chardata = {};
		end
		local curr_ns,name = tagname:match(ns_pattern);
		if name == "" then
			curr_ns, name = "", curr_ns;
		end

		if curr_ns ~= stream_default_ns or non_streamns_depth > 0 then
			attr.xmlns = curr_ns;
			non_streamns_depth = non_streamns_depth + 1;
		end
		
		for i=1,#attr do
			local k = attr[i];
			attr[i] = nil;
			local xmlk = xml_namespace[k];
			if xmlk then
				attr[xmlk] = attr[k];
				attr[k] = nil;
			end
		end
		
		if not stanza then --if we are not currently inside a stanza
			if session.notopen then
				if tagname == stream_tag then
					non_streamns_depth = 0;
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
			
			stanza = setmetatable({ name = name, attr = attr, tags = {} }, stanza_mt);
		else -- we are inside a stanza, so add a tag
			t_insert(stack, stanza);
			local oldstanza = stanza;
			stanza = setmetatable({ name = name, attr = attr, tags = {} }, stanza_mt);
			t_insert(oldstanza, stanza);
			t_insert(oldstanza.tags, stanza);
		end
	end
	function xml_handlers:CharacterData(data)
		if stanza then
			t_insert(chardata, data);
		end
	end
	function xml_handlers:EndElement(tagname)
		if non_streamns_depth > 0 then
			non_streamns_depth = non_streamns_depth - 1;
		end
		if stanza then
			if #chardata > 0 then
				-- We have some character data in the buffer
				t_insert(stanza, t_concat(chardata));
				chardata = {};
			end
			-- Complete stanza
			if #stack == 0 then
				if tagname ~= stream_error_tag then
					cb_handlestanza(session, stanza);
				else
					cb_error(session, "stream-error", stanza);
				end
				stanza = nil;
			else
				stanza = t_remove(stack);
			end
		else
			if cb_streamclosed then
				cb_streamclosed(session);
			end
		end
	end

	local function restricted_handler(parser)
		cb_error(session, "parse-error", "restricted-xml", "Restricted XML, see RFC 6120 section 11.1.");
		if not parser.stop or not parser:stop() then
			error("Failed to abort parsing");
		end
	end
	
	if lxp_supports_doctype then
		xml_handlers.StartDoctypeDecl = restricted_handler;
	end
	xml_handlers.Comment = restricted_handler;
	xml_handlers.ProcessingInstruction = restricted_handler;
	
	local function reset()
		stanza, chardata = nil, {};
		stack = {};
	end
	
	local function set_session(stream, new_session)
		session = new_session;
	end
	
	return xml_handlers, { reset = reset, set_session = set_session };
end

function new(session, stream_callbacks)
	local handlers, meta = new_sax_handlers(session, stream_callbacks);
	local parser = new_parser(handlers, ns_separator);
	local parse = parser.parse;

	return {
		reset = function ()
			parser = new_parser(handlers, ns_separator);
			parse = parser.parse;
			meta.reset();
		end,
		feed = function (self, data)
			return parse(parser, data);
		end,
		set_session = meta.set_session;
	};
end

return _M;
