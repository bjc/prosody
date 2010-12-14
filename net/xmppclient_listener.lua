-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local logger = require "logger";
local log = logger.init("xmppclient_listener");
local new_xmpp_stream = require "util.xmppstream".new;

local connlisteners_register = require "net.connlisteners".register;

local sessionmanager = require "core.sessionmanager";
local sm_new_session, sm_destroy_session = sessionmanager.new_session, sessionmanager.destroy_session;
local sm_streamopened = sessionmanager.streamopened;
local sm_streamclosed = sessionmanager.streamclosed;
local st = require "util.stanza";
local xpcall = xpcall;
local tostring = tostring;
local type = type;
local traceback = debug.traceback;

local config = require "core.configmanager";
local opt_keepalives = config.get("*", "core", "tcp_keepalives");

local stream_callbacks = { default_ns = "jabber:client",
		streamopened = sm_streamopened, streamclosed = sm_streamclosed, handlestanza = core_process_stanza };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session.log("debug", "Invalid opening stream header");
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		(session.log or log)("debug", "Client XML parse error: %s", tostring(data));
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

local function handleerr(err) log("error", "Traceback[c2s]: %s: %s", tostring(err), traceback()); end
function stream_callbacks.handlestanza(session, stanza)
	stanza = session.filter("stanzas/in", stanza);
	if stanza then
		return xpcall(function () return core_process_stanza(session, stanza) end, handleerr);
	end
end

local sessions = {};
local xmppclient = { default_port = 5222, default_mode = "*a" };

-- These are session methods --

local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = stream_callbacks.default_ns, version = "1.0", id = "" };
local function session_close(session, reason)
	local log = session.log or log;
	if session.conn then
		if session.notopen then
			session.send("<?xml version='1.0'?>");
			session.send(st.stanza("stream:stream", default_stream_attr):top_tag());
		end
		if reason then
			if type(reason) == "string" then -- assume stream error
				log("info", "Disconnecting client, <stream:error> is: %s", reason);
				session.send(st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }));
			elseif type(reason) == "table" then
				if reason.condition then
					local stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					log("info", "Disconnecting client, <stream:error> is: %s", tostring(stanza));
					session.send(stanza);
				elseif reason.name then -- a stanza
					log("info", "Disconnecting client, <stream:error> is: %s", tostring(reason));
					session.send(reason);
				end
			end
		end
		session.send("</stream:stream>");
		session.conn:close();
		xmppclient.ondisconnect(session.conn, (reason and (reason.text or reason.condition)) or reason or "session closed");
	end
end


-- End of session methods --

function xmppclient.onconnect(conn)
	local session = sm_new_session(conn);
	sessions[conn] = session;
	
	session.log("info", "Client connected");
	
	-- Client is using legacy SSL (otherwise mod_tls sets this flag)
	if conn:ssl() then
		session.secure = true;
	end
	
	if opt_keepalives ~= nil then
		conn:setoption("keepalive", opt_keepalives);
	end
	
	session.close = session_close;
	
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
			log("debug", "Received invalid XML (%s) %d bytes: %s", tostring(err), #data, data:sub(1, 300):gsub("[\r\n]+", " "):gsub("[%z\1-\31]", "_"));
			session:close("not-well-formed");
		end
	end
	
	local handlestanza = stream_callbacks.handlestanza;
	function session.dispatch_stanza(session, stanza)
		return handlestanza(session, stanza);
	end
end

function xmppclient.onincoming(conn, data)
	local session = sessions[conn];
	if session then
		session.data(data);
	end
end
	
function xmppclient.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		(session.log or log)("info", "Client disconnected: %s", err);
		sm_destroy_session(session, err);
		sessions[conn]  = nil;
		session = nil;
	end
end

function xmppclient.associate_session(conn, session)
	sessions[conn] = session;
end

connlisteners_register("xmppclient", xmppclient);
