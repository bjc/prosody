-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local tostring = tostring;
local type = type;
local xpcall = xpcall;
local s_format = string.format;
local traceback = debug.traceback;

local logger = require "logger";
local log = logger.init("xmppserver_listener");
local st = require "util.stanza";
local connlisteners_register = require "net.connlisteners".register;
local new_xmpp_stream = require "util.xmppstream".new;
local s2s_new_incoming = require "core.s2smanager".new_incoming;
local s2s_streamopened = require "core.s2smanager".streamopened;
local s2s_streamclosed = require "core.s2smanager".streamclosed;
local s2s_destroy_session = require "core.s2smanager".destroy_session;
local s2s_attempt_connect = require "core.s2smanager".attempt_connection;
local stream_callbacks = { default_ns = "jabber:server",
		streamopened = s2s_streamopened, streamclosed = s2s_streamclosed, handlestanza =  core_process_stanza };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		session.log("debug", "Server-to-server XML parse error: %s", tostring(error));
		session:close("not-well-formed");
	elseif error == "stream-error" then
		local condition, text = "undefined-condition";
		for child in data:children() do
			if child.attr.xmlns == xmlns_xmpp_streams then
				if child.name ~= "text" then
					condition = child.name;
				else
					text = child:get_text();
				end
				if condition ~= "undefined-condition" and text then
					break;
				end
			end
		end
		text = condition .. (text and (" ("..text..")") or "");
		session.log("info", "Session closed by remote with error: %s", text);
		session:close(nil, text);
	end
end

local function handleerr(err) log("error", "Traceback[s2s]: %s: %s", tostring(err), traceback()); end
function stream_callbacks.handlestanza(session, stanza)
	if stanza.attr.xmlns == "jabber:client" then --COMPAT: Prosody pre-0.6.2 may send jabber:client
		stanza.attr.xmlns = nil;
	end
	stanza = session.filter("stanzas/in", stanza);
	if stanza then
		return xpcall(function () return core_process_stanza(session, stanza) end, handleerr);
	end
end

local sessions = {};
local xmppserver = { default_port = 5269, default_mode = "*a" };

-- These are session methods --

local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = stream_callbacks.default_ns, version = "1.0", id = "" };
local function session_close(session, reason, remote_reason)
	local log = session.log or log;
	if session.conn then
		if session.notopen then
			session.sends2s("<?xml version='1.0'?>");
			session.sends2s(st.stanza("stream:stream", default_stream_attr):top_tag());
		end
		if reason then
			if type(reason) == "string" then -- assume stream error
				log("info", "Disconnecting %s[%s], <stream:error> is: %s", session.host or "(unknown host)", session.type, reason);
				session.sends2s(st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }));
			elseif type(reason) == "table" then
				if reason.condition then
					local stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					log("info", "Disconnecting %s[%s], <stream:error> is: %s", session.host or "(unknown host)", session.type, tostring(stanza));
					session.sends2s(stanza);
				elseif reason.name then -- a stanza
					log("info", "Disconnecting %s->%s[%s], <stream:error> is: %s", session.from_host or "(unknown host)", session.to_host or "(unknown host)", session.type, tostring(reason));
					session.sends2s(reason);
				end
			end
		end
		session.sends2s("</stream:stream>");
		if session.notopen or not session.conn:close() then
			session.conn:close(true); -- Force FIXME: timer?
		end
		session.conn:close();
		xmppserver.ondisconnect(session.conn, remote_reason or (reason and (reason.text or reason.condition)) or reason or "stream closed");
	end
end


-- End of session methods --

local function initialize_session(session)
	local stream = new_xmpp_stream(session, stream_callbacks);
	session.stream = stream;
	
	session.notopen = true;
		
	function session.reset_stream()
		session.notopen = true;
		session.stream:reset();
	end
	
	local filter = session.filter;
	function session.data(data)
		data = filter("bytes/in", data);
		if data then
			local ok, err = stream:feed(data);
			if ok then return; end
			(session.log or log)("warn", "Received invalid XML: %s", data);
			(session.log or log)("warn", "Problem was: %s", err);
			session:close("not-well-formed");
		end
	end

	session.close = session_close;
	local handlestanza = stream_callbacks.handlestanza;
	function session.dispatch_stanza(session, stanza)
		return handlestanza(session, stanza);
	end
end

function xmppserver.onconnect(conn)
	if not sessions[conn] then -- May be an existing outgoing session
		local session = s2s_new_incoming(conn);
		sessions[conn] = session;
	
		-- Logging functions --
		local conn_name = "s2sin"..tostring(conn):match("[a-f0-9]+$");
		session.log = logger.init(conn_name);
		
		session.log("info", "Incoming s2s connection");
		
		initialize_session(session);
	end
end

function xmppserver.onincoming(conn, data)
	local session = sessions[conn];
	if session then
		session.data(data);
	end
end
	
function xmppserver.onstatus(conn, status)
	if status == "ssl-handshake-complete" then
		local session = sessions[conn];
		if session and session.direction == "outgoing" then
			local to_host, from_host = session.to_host, session.from_host;
			session.log("debug", "Sending stream header...");
			session.sends2s(s_format([[<stream:stream xmlns='jabber:server' xmlns:db='jabber:server:dialback' xmlns:stream='http://etherx.jabber.org/streams' from='%s' to='%s' version='1.0'>]], from_host, to_host));
		end
	end
end

function xmppserver.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		if err and err ~= "closed" and session.srv_hosts then
			(session.log or log)("debug", "s2s connection attempt failed: %s", err);
			if s2s_attempt_connect(session, err) then
				(session.log or log)("debug", "...so we're going to try another target");
				return; -- Session lives for now
			end
		end
		(session.log or log)("info", "s2s disconnected: %s->%s (%s)", tostring(session.from_host), tostring(session.to_host), tostring(err or "closed"));
		s2s_destroy_session(session, err);
		sessions[conn]  = nil;
		session = nil;
	end
end

function xmppserver.register_outgoing(conn, session)
	session.direction = "outgoing";
	sessions[conn] = session;
	
	initialize_session(session);
end

connlisteners_register("xmppserver", xmppserver);


-- We need to perform some initialisation when a connection is created
-- We also need to perform that same initialisation at other points (SASL, TLS, ...)

-- ...and we need to handle data
-- ...and record all sessions associated with connections
