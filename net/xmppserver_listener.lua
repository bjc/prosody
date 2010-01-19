-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local logger = require "logger";
local log = logger.init("xmppserver_listener");
local lxp = require "lxp"
local init_xmlhandlers = require "core.xmlhandlers"
local s2s_new_incoming = require "core.s2smanager".new_incoming;
local s2s_streamopened = require "core.s2smanager".streamopened;
local s2s_streamclosed = require "core.s2smanager".streamclosed;
local s2s_destroy_session = require "core.s2smanager".destroy_session;
local s2s_attempt_connect = require "core.s2smanager".attempt_connection;
local stream_callbacks = { default_ns = "jabber:server",
		streamopened = s2s_streamopened, streamclosed = s2s_streamclosed, handlestanza =  core_process_stanza };

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session:close("invalid-namespace");
	else
		session.log("debug", "Server-to-server XML parse error: %s", tostring(error));
		session:close("xml-not-well-formed");
	end
end

local function handleerr(err) log("error", "Traceback[s2s]: %s: %s", tostring(err), debug.traceback()); end
function stream_callbacks.handlestanza(a, b)
	xpcall(function () core_process_stanza(a, b) end, handleerr);
end

local connlisteners_register = require "net.connlisteners".register;

local t_insert = table.insert;
local t_concat = table.concat;
local t_concatall = function (t, sep) local tt = {}; for _, s in ipairs(t) do t_insert(tt, tostring(s)); end return t_concat(tt, sep); end
local m_random = math.random;
local format = string.format;
local sessionmanager = require "core.sessionmanager";
local sm_new_session, sm_destroy_session = sessionmanager.new_session, sessionmanager.destroy_session;
local st = require "util.stanza";

local sessions = {};
local xmppserver = { default_port = 5269, default_mode = "*a" };

-- These are session methods --

local function session_reset_stream(session)
	-- Reset stream
		local parser = lxp.new(init_xmlhandlers(session, stream_callbacks), "\1");
		session.parser = parser;
		
		session.notopen = true;
		
		function session.data(conn, data)
			local ok, err = parser:parse(data);
			if ok then return; end
			(session.log or log)("warn", "Received invalid XML: %s", data);
			(session.log or log)("warn", "Problem was: %s", err);
			session:close("xml-not-well-formed");
		end
		
		return true;
end

local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = stream_callbacks.default_ns, version = "1.0", id = "" };
local function session_close(session, reason)
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
		xmppserver.ondisconnect(session.conn, (reason and (reason.text or reason.condition)) or reason or "stream closed");
	end
end


-- End of session methods --

function xmppserver.onincoming(conn, data)
	local session = sessions[conn];
	if not session then
		session = s2s_new_incoming(conn);
		sessions[conn] = session;

		-- Logging functions --

		
		local conn_name = "s2sin"..tostring(conn):match("[a-f0-9]+$");
		session.log = logger.init(conn_name);
		
		session.log("info", "Incoming s2s connection");
		
		session.reset_stream = session_reset_stream;
		session.close = session_close;
		
		session_reset_stream(session); -- Initialise, ready for use
		
		session.dispatch_stanza = stream_callbacks.handlestanza;
	end
	if data then
		session.data(conn, data);
	end
end
	
function xmppserver.status(conn, status)
	if status == "ssl-handshake-complete" then
		local session = sessions[conn];
		if session and session.direction == "outgoing" then
			local format, to_host, from_host = string.format, session.to_host, session.from_host;
			session.log("debug", "Sending stream header...");
			session.sends2s(format([[<stream:stream xmlns='jabber:server' xmlns:db='jabber:server:dialback' xmlns:stream='http://etherx.jabber.org/streams' from='%s' to='%s' version='1.0'>]], from_host, to_host));
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
		(session.log or log)("info", "s2s disconnected: %s->%s (%s)", tostring(session.from_host), tostring(session.to_host), tostring(err));
		s2s_destroy_session(session, err);
		sessions[conn]  = nil;
		session = nil;
	end
end

function xmppserver.register_outgoing(conn, session)
	session.direction = "outgoing";
	sessions[conn] = session;
	
	session.reset_stream = session_reset_stream;
	session.close = session_close;
	session_reset_stream(session); -- Initialise, ready for use
	
	--local function handleerr(err) print("Traceback:", err, debug.traceback()); end
	--session.stanza_dispatch = function (stanza) return select(2, xpcall(function () return core_process_stanza(session, stanza); end, handleerr));  end
end

connlisteners_register("xmppserver", xmppserver);


-- We need to perform some initialisation when a connection is created
-- We also need to perform that same initialisation at other points (SASL, TLS, ...)

-- ...and we need to handle data
-- ...and record all sessions associated with connections
